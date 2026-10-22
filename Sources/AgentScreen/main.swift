import AgentScreenCore
import AppKit
import ServiceManagement

let port: UInt16 = 8977
let proxyURL = "http://127.0.0.1:\(port)"
let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Agent Screen")
let keyFile = support.appendingPathComponent("superagent-api-key")
let flagLog = FlagLog(url: support.appendingPathComponent("flags.jsonl"))

func readAPIKey() -> String? {
    (try? String(contentsOf: keyFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var proxy: Proxy!
    private let screener = Screener(apiKey: readAPIKey, log: flagLog)
    private var proxyError: String?
    private var screeningError: String?
    private var unseenFlags = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        refreshIcon()

        screener.onFlag = { _ in DispatchQueue.main.async { self.unseenFlags += 1; self.refreshIcon() } }
        screener.onStatus = { error in DispatchQueue.main.async { self.screeningError = error } }

        do {
            proxy = try Proxy(port: port)
            proxy.onRequest = { [screener] request in Task.detached { await screener.screen(request) } }
            proxy.start { result in
                DispatchQueue.main.async {
                    if case .failure(let error) = result { self.proxyError = "\(error)" }
                    self.refreshIcon()
                }
            }
        } catch {
            proxyError = "\(error)"
            refreshIcon()
        }
    }

    private func refreshIcon() {
        let symbol = proxyError != nil ? "xmark.shield" : unseenFlags > 0 ? "exclamationmark.shield.fill" : "checkmark.shield"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Agent Screen")
        statusItem.button?.title = unseenFlags > 0 ? " \(unseenFlags)" : ""
    }

    // Rebuilt on every open so it always shows the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(item(proxyURL, #selector(copyURL), subtitle: "Click to copy. Set as ANTHROPIC_BASE_URL."))
        menu.addItem(.separator())

        if let proxyError {
            menu.addItem(disabled("Proxy failed: \(proxyError)"))
        } else if readAPIKey()?.isEmpty ?? true {
            menu.addItem(disabled("No Superagent API key: passing traffic through unscreened"))
        } else if let screeningError {
            menu.addItem(disabled("Screening error: \(screeningError)"))
        } else {
            menu.addItem(disabled("Screening tool results with Security-One"))
        }

        let flags = flagLog.recent(10)
        menu.addItem(.separator())
        menu.addItem(disabled(flags.isEmpty ? "No flags" : "Recent flags (score ≥ \(SecurityOne.threshold))"))
        for flag in flags {
            let time = flag.time.formatted(date: .abbreviated, time: .shortened)
            menu.addItem(item("\(time)  \(String(format: "%.2f", flag.score))  \(flag.tool)  \(flag.source.prefix(60))", #selector(openLog), subtitle: String(flag.excerpt.prefix(120))))
        }
        if !flags.isEmpty {
            menu.addItem(item("Open Flag Log", #selector(openLog)))
            menu.addItem(item("Mark Flags Seen", #selector(markSeen)))
        }

        menu.addItem(.separator())
        menu.addItem(item("Set Superagent API Key…", #selector(setAPIKey)))
        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Quit Agent Screen", #selector(NSApplication.terminate(_:)), target: NSApp))
    }

    private func item(_ title: String, _ action: Selector, subtitle: String? = nil, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target ?? self
        item.subtitle = subtitle
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(proxyURL, forType: .string)
    }

    @objc private func openLog() {
        NSWorkspace.shared.activateFileViewerSelecting([flagLog.url])
        markSeen()
    }

    @objc private func markSeen() {
        unseenFlags = 0
        refreshIcon()
    }

    @objc private func setAPIKey() {
        let alert = NSAlert()
        alert.messageText = "Superagent API key"
        alert.informativeText = "Stored in \(keyFile.path), readable by your user only."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: keyFile.path, contents: Data(field.stringValue.utf8), attributes: [.posixPermissions: 0o600])
        screeningError = nil
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        try? service.status == .enabled ? service.unregister() : service.register()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
