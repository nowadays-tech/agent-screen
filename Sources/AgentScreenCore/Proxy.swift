import Foundation
import Network

/// A local HTTP proxy that forwards every request to `upstream` and streams the reply back unchanged.
/// It hands each request to `onRequest` on the side; it never waits for it or alters traffic.
public final class Proxy {
    public let upstream: URL
    public var onRequest: ((HTTPRequest) -> Void)?

    private let listener: NWListener
    private let forwarder: Forwarder
    private let queue = DispatchQueue(label: "agent-screen.proxy")

    public init(port: UInt16, upstream: URL = URL(string: "https://api.anthropic.com")!, configuration: URLSessionConfiguration = .default) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: parameters)
        self.upstream = upstream
        self.forwarder = Forwarder(configuration: configuration)
    }

    /// Starts listening and calls `ready` with the bound port, or with the error.
    public func start(ready: @escaping (Result<UInt16, Error>) -> Void) {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            ClientConnection(connection: connection, proxy: self).start()
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: ready(.success(self?.listener.port?.rawValue ?? 0))
            case .failed(let error): ready(.failure(error))
            default: break
            }
        }
        listener.start(queue: queue)
    }

    public func stop() { listener.cancel() }

    fileprivate func forward(_ request: HTTPRequest, to client: ClientConnection) -> URLSessionDataTask? {
        onRequest?(request)
        return forwarder.forward(request, upstream: upstream, to: client)
    }
}

/// One client socket. Serves requests one at a time and writes each reply with chunked framing.
/// A read stays pending the whole time, so a client that hangs up mid-reply cancels the upstream request.
private final class ClientConnection {
    private let connection: NWConnection
    private let proxy: Proxy
    private let queue = DispatchQueue(label: "agent-screen.client")
    private var buffer = Data()
    private var keepAlive = true
    private var bodyless = false
    private var headSent = false
    private var upstreamTask: URLSessionDataTask?
    private var closed = false

    init(connection: NWConnection, proxy: Proxy) {
        self.connection = connection
        self.proxy = proxy
    }

    func start() {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, isComplete, error in
            guard !closed else { return }
            if let data { buffer.append(data) }
            if isComplete || error != nil {
                // The client hung up. Stop the model from generating a reply nobody reads.
                upstreamTask?.cancel()
                closed = true
                connection.cancel()
                return
            }
            serveNext()
            receive()
        }
    }

    private func serveNext() {
        guard upstreamTask == nil, !closed else { return }
        switch HTTPRequest.parse(buffer) {
        case .request(let request, let consumed):
            buffer = buffer.subdata(in: consumed..<buffer.count)
            keepAlive = request.header("Connection")?.lowercased() != "close"
            bodyless = request.method == "HEAD"
            headSent = false
            upstreamTask = proxy.forward(request, to: self)
        case .incomplete:
            break
        case .invalid:
            close(after: Data("HTTP/1.1 400 Bad Request\r\ncontent-length: 0\r\nconnection: close\r\n\r\n".utf8))
        }
    }

    // Called from the URLSession delegate queue; hop onto this connection's queue.

    func respond(head response: HTTPURLResponse) {
        queue.async { [self] in
            if response.statusCode == 204 || response.statusCode == 304 { bodyless = true }
            var head = "HTTP/1.1 \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))\r\n"
            for (name, value) in response.allHeaderFields {
                let name = "\(name)"
                // URLSession has already decoded the body and owns the framing.
                if ["content-length", "content-encoding", "transfer-encoding", "connection", "keep-alive"].contains(name.lowercased()) { continue }
                head += "\(name): \(value)\r\n"
            }
            head += bodyless ? "content-length: 0\r\n" : "transfer-encoding: chunked\r\n"
            head += keepAlive ? "\r\n" : "connection: close\r\n\r\n"
            write(Data(head.utf8))
            headSent = true
        }
    }

    func respond(body data: Data) {
        queue.async { [self] in
            guard !bodyless, !data.isEmpty else { return }
            var chunk = Data(String(data.count, radix: 16).utf8)
            chunk.append(contentsOf: Array("\r\n".utf8))
            chunk.append(data)
            chunk.append(contentsOf: Array("\r\n".utf8))
            write(chunk)
        }
    }

    func finish(error: Error?) {
        queue.async { [self] in
            upstreamTask = nil
            guard !closed else { return }
            if error != nil && !headSent {
                close(after: Data("HTTP/1.1 502 Bad Gateway\r\ncontent-length: 0\r\nconnection: close\r\n\r\n".utf8))
                return
            }
            if error != nil {
                // The reply was cut off midway; a clean terminator would hide that.
                closed = true
                connection.cancel()
                return
            }
            let end = bodyless ? Data() : Data("0\r\n\r\n".utf8)
            if keepAlive {
                write(end)
                serveNext()
            } else {
                close(after: end)
            }
        }
    }

    private func write(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    // A cancel right after a send can drop the bytes, so cancel once they are out.
    private func close(after data: Data) {
        closed = true
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }
}

/// Sends requests upstream on one shared URLSession and streams each reply to its client.
private final class Forwarder: NSObject, URLSessionDataDelegate {
    private static let hopHeaders: Set<String> = ["host", "content-length", "connection", "keep-alive", "transfer-encoding", "te", "upgrade", "proxy-connection", "accept-encoding"]

    private var session: URLSession!
    private var clients: [Int: ClientConnection] = [:]
    private let lock = NSLock()

    init(configuration: URLSessionConfiguration) {
        super.init()
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3600
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func forward(_ request: HTTPRequest, upstream: URL, to client: ClientConnection) -> URLSessionDataTask? {
        guard let url = URL(string: upstream.absoluteString + request.target) else {
            client.finish(error: URLError(.badURL))
            return nil
        }
        var upstreamRequest = URLRequest(url: url)
        upstreamRequest.httpMethod = request.method
        for (name, value) in request.headers where !Self.hopHeaders.contains(name.lowercased()) {
            upstreamRequest.addValue(value, forHTTPHeaderField: name)
        }
        if !request.body.isEmpty { upstreamRequest.httpBody = request.body }

        let task = session.dataTask(with: upstreamRequest)
        lock.withLock { clients[task.taskIdentifier] = client }
        task.resume()
        return task
    }

    private func client(for task: URLSessionTask) -> ClientConnection? {
        lock.withLock { clients[task.taskIdentifier] }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let response = response as? HTTPURLResponse { client(for: dataTask)?.respond(head: response) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        client(for: dataTask)?.respond(body: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let client = lock.withLock { clients.removeValue(forKey: task.taskIdentifier) }
        client?.finish(error: error)
    }

    // Pass redirects through to the client instead of following them.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
