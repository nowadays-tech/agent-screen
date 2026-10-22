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
    private var lastCheck: Screener.Check?
    private var unseenFlags = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = editMenu()
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        statusItem.menu?.autoenablesItems = false
        refreshIcon()

        screener.onFlag = { _ in DispatchQueue.main.async { self.unseenFlags += 1; self.refreshIcon() } }
        screener.onCheck = { check in DispatchQueue.main.async { self.lastCheck = check; self.refreshIcon() } }

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

    /// An accessory app has no menu bar of its own, so ⌘V in the key field has nothing to trigger.
    /// A hidden Edit menu supplies the standard shortcuts.
    private func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem()
        item.submenu = edit
        let main = NSMenu()
        main.addItem(item)
        return main
    }

    private enum State { case off, failing, screening, flagged }

    private var state: State {
        if proxyError != nil { return .failing }
        if unseenFlags > 0 { return .flagged }
        if readAPIKey()?.isEmpty ?? true { return .off }
        if case .failed = lastCheck { return .failing }
        return .screening
    }

    private func refreshIcon() {
        let button = statusItem.button
        switch state {
        case .off: button?.image = symbol("shield.slash")
        case .failing: button?.image = symbol("xmark.shield")
        case .screening: button?.image = symbol("checkmark.shield")
        case .flagged: button?.image = symbol("exclamationmark.shield.fill")
        }
        button?.contentTintColor = state == .flagged ? .systemRed : nil
        button?.title = unseenFlags > 0 ? "\(unseenFlags)" : ""
        button?.imagePosition = .imageLeading
    }

    // Rebuilt on every open so it always shows the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(.sectionHeader(title: "Agent Screen"))
        menu.addItem(item(proxyURL, symbol: "link", action: #selector(copyURL), subtitle: "Click to copy. Use as ANTHROPIC_BASE_URL."))
        menu.addItem(statusLine())

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Flags"))
        let flags = flagLog.recent(8)
        if flags.isEmpty {
            menu.addItem(item("No flags yet", symbol: "checkmark.circle"))
        }
        for flag in flags {
            let when = flag.time.formatted(.relative(presentation: .named))
            let details = "\(flag.tool) · \(String(format: "%.2f", flag.score)) · \(when)\n\(flag.excerpt.prefix(90))"
            menu.addItem(item(String(flag.source.prefix(50)), symbol: "exclamationmark.triangle.fill", tint: .systemRed, action: #selector(openLog), subtitle: details))
        }
        if !flags.isEmpty {
            menu.addItem(item("Show Flag Log", symbol: "doc.text.magnifyingglass", action: #selector(openLog)))
        }

        menu.addItem(.separator())
        menu.addItem(item("Superagent API Key…", symbol: "key", action: #selector(setAPIKey)))
        let login = item("Open at Login", symbol: "power", action: #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let quit = item("Quit Agent Screen", symbol: "xmark.rectangle", action: #selector(NSApplication.terminate(_:)), target: NSApp)
        quit.keyEquivalent = "q"
        menu.addItem(quit)

        // Opening the menu is looking at the flags.
        unseenFlags = 0
        refreshIcon()
    }

    private func statusLine() -> NSMenuItem {
        if let proxyError {
            return item("Proxy stopped", symbol: "circle.fill", tint: .systemRed, subtitle: proxyError)
        }
        if readAPIKey()?.isEmpty ?? true {
            return item("Not screening", symbol: "circle.fill", tint: .systemGray, subtitle: "Add a Superagent API key to start.")
        }
        switch lastCheck {
        case .failed(let error):
            return item("Screening failed", symbol: "circle.fill", tint: .systemOrange, subtitle: error)
        case .scored(let seconds):
            return item("Screening with Security-One", symbol: "circle.fill", tint: .systemGreen, subtitle: "Last check took \(String(format: "%.2f", seconds)) s.")
        case nil:
            return item("Screening with Security-One", symbol: "circle.fill", tint: .systemGreen, subtitle: "Waiting for the first tool result.")
        }
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func item(_ title: String, symbol name: String, tint: NSColor? = nil, action: Selector? = nil, subtitle: String? = nil, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target ?? self
        item.subtitle = subtitle
        var image = symbol(name)
        if let tint {
            image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint]))
        }
        item.image = image
        return item
    }

    @objc private func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(proxyURL, forType: .string)
    }

    @objc private func openLog() {
        NSWorkspace.shared.activateFileViewerSelecting([flagLog.url])
    }

    @objc private func setAPIKey() {
        let alert = NSAlert()
        alert.icon = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
        alert.messageText = "Superagent API key"
        alert.informativeText = (readAPIKey()?.isEmpty ?? true)
            ? "Paste your key. It is stored in Application Support, readable by your user only."
            : "A key is saved. Paste a new one to replace it."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "API key"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: keyFile.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600])
        lastCheck = nil
        refreshIcon()
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
