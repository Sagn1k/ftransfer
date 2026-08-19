// ftransfer menu bar app — share folders to your phone via a Cloudflare quick
// tunnel. On launch it asks which folders to share, then pops up a QR code
// window; the 📦 menu bar icon controls it afterwards. Spawns the bundled
// server.py plus cloudflared.

import AppKit
import CoreImage

// MARK: - Helpers

// no 0/O, 1/l/i — painless to type on a phone keyboard
private let pwAlphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

private func randomPassword(length: Int = 10) -> String {
    String((0..<length).map { _ in pwAlphabet.randomElement()! })
}

private func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let m = re.firstMatch(in: text, range: range),
          let r = Range(m.range, in: text) else { return nil }
    return String(text[r])
}

private func qrImage(for string: String, sideLength: CGFloat) -> NSImage? {
    guard let data = string.data(using: .ascii),
          let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    let scale = sideLength / output.extent.width
    let scaled = output.samplingNearest()
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
}

/// Accumulates pipe chunks and hands back whole lines.
private final class LineBuffer {
    private var partial = ""
    func feed(_ chunk: String) -> [String] {
        partial += chunk
        var lines = partial.components(separatedBy: "\n")
        partial = lines.removeLast()
        return lines
    }
}

// MARK: - Share session

private final class ShareSession {
    let folders: [URL]
    let password = randomPassword()
    var port: Int?
    var url: String?
    var registered = false
    var stopRequested = false
    var serverProcess: Process?
    var tunnelProcess: Process?
    var logTail: [String] = []

    init(folders: [URL]) { self.folders = folders }

    var folderSummary: String {
        folders.count == 1 ? folders[0].lastPathComponent
                           : "\(folders.count) folders"
    }

    func remember(_ line: String) {
        logTail.append(line)
        if logTail.count > 30 { logTail.removeFirst() }
    }

    func terminateProcesses() {
        stopRequested = true
        for p in [serverProcess, tunnelProcess] where p?.isRunning == true {
            p?.terminate()
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum State { case idle, starting, live }

    private var statusItem: NSStatusItem!
    private var state: State = .idle
    private var session: ShareSession?
    private var qrWindow: NSWindow?

    private let lastFolderKey = "lastSharedFolder"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        rebuildUI()
        // Go straight into the flow the user expects: pick folders, get a QR.
        DispatchQueue.main.async { [weak self] in
            self?.chooseFoldersAndStart(fromLaunch: true)
        }
    }

    /// Double-clicking the app in Finder/Dock while it's already running.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        switch state {
        case .live: showQRWindow()
        case .idle: chooseFoldersAndStart(fromLaunch: false)
        case .starting: break
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.terminateProcesses()
    }

    // MARK: UI

    private func rebuildUI() {
        let symbol = state == .live ? "shippingbox.fill" : "shippingbox"
        statusItem.button?.image = NSImage(systemSymbolName: symbol,
                                           accessibilityDescription: "ftransfer")
        statusItem.button?.appearsDisabled = (state == .starting)

        let menu = NSMenu()
        switch state {
        case .idle:
            menu.addItem(disabled("Not sharing"))
            menu.addItem(.separator())
            menu.addItem(item("Start Sharing…", #selector(startSharingClicked), key: "s"))
        case .starting:
            menu.addItem(disabled("Starting tunnel…"))
            menu.addItem(.separator())
            menu.addItem(item("Cancel", #selector(stopSharing), key: ""))
        case .live:
            menu.addItem(disabled("Sharing \(session?.folderSummary ?? "?")"))
            for folder in (session?.folders ?? []).prefix(5) {
                menu.addItem(disabled("  📁 \(folder.lastPathComponent)"))
            }
            if let url = session?.url {
                menu.addItem(disabled(url.replacingOccurrences(of: "https://", with: "")))
            }
            menu.addItem(.separator())
            menu.addItem(item("Show QR Code", #selector(showQRWindow), key: "q"))
            menu.addItem(item("Copy Link", #selector(copyLink), key: "c"))
            menu.addItem(item("Copy Password", #selector(copyPassword), key: ""))
            menu.addItem(item("Open Shared Folder", #selector(openFolders), key: "o"))
            menu.addItem(.separator())
            menu.addItem(item("Stop Sharing", #selector(stopSharing), key: "s"))
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit ftransfer", #selector(quit), key: ""))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    // MARK: Actions

    @objc private func startSharingClicked() {
        chooseFoldersAndStart(fromLaunch: false)
    }

    private func chooseFoldersAndStart(fromLaunch: Bool) {
        guard state == .idle else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Share"
        panel.title = "ftransfer"
        panel.message = "Choose the folder(s) to share to your phone. "
                      + "Cmd-click to select more than one."
        if let last = UserDefaults.standard.string(forKey: lastFolderKey) {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else {
            if fromLaunch {
                alert("ftransfer lives in your menu bar",
                      "Click the 📦 icon in the menu bar (top right) whenever "
                      + "you want to start or stop sharing.\n\nTip: on MacBooks "
                      + "with a notch, a crowded menu bar can hide new icons.")
            }
            return
        }
        UserDefaults.standard.set(panel.urls[0].path, forKey: lastFolderKey)
        startSharing(folders: panel.urls)
    }

    @objc private func stopSharing() {
        session?.terminateProcesses()
        session = nil
        state = .idle
        qrWindow?.close()
        rebuildUI()
    }

    @objc private func copyLink() {
        guard let url = session?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc private func copyPassword() {
        guard let s = session else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s.password, forType: .string)
    }

    @objc private func openFolders() {
        for folder in session?.folders ?? [] {
            NSWorkspace.shared.open(folder)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Start / monitor

    private func startSharing(folders: [URL]) {
        guard state == .idle else { return }
        guard let serverScript = Bundle.main.path(forResource: "server", ofType: "py") else {
            alert("Missing server.py", "The app bundle is incomplete — rebuild with build.sh.")
            return
        }
        guard let cloudflared = findCloudflared() else {
            alert("cloudflared not found",
                  "Install it first:\n\nbrew install cloudflared")
            return
        }

        let s = ShareSession(folders: folders)
        session = s
        state = .starting
        rebuildUI()

        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [serverScript] + folders.map(\.path)
                         + ["--port", "0", "--password", s.password]
        attach(process: server, to: s, tag: "server") { [weak self] line in
            if s.port == nil,
               let portText = firstMatch(#"listening http://[0-9.]+:([0-9]+)"#, in: line),
               let colon = portText.lastIndex(of: ":"),
               let port = Int(portText[portText.index(after: colon)...]) {
                s.port = port
                self?.launchTunnel(for: s, cloudflared: cloudflared, port: port)
            }
        }
        do {
            try server.run()
            s.serverProcess = server
        } catch {
            fail(s, "Could not start the local server", detail: error.localizedDescription)
            return
        }

        // Watchdog: give the whole startup 40 seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in
            guard let self, self.session === s, self.state == .starting else { return }
            self.fail(s, "Tunnel didn’t connect within 40 seconds",
                      detail: s.logTail.suffix(8).joined(separator: "\n"))
        }
    }

    private func launchTunnel(for s: ShareSession, cloudflared: String, port: Int) {
        guard session === s else { return }
        let tunnel = Process()
        tunnel.executableURL = URL(fileURLWithPath: cloudflared)
        // http2 (TCP) instead of quic (UDP): corporate networks often drop UDP 7844.
        tunnel.arguments = ["tunnel", "--url", "http://127.0.0.1:\(port)",
                            "--protocol", "http2", "--no-autoupdate"]
        attach(process: tunnel, to: s, tag: "tunnel") { [weak self] line in
            if s.url == nil,
               let url = firstMatch(#"https://[a-z0-9-]+\.trycloudflare\.com"#, in: line) {
                s.url = url
            }
            if line.contains("Registered tunnel connection") { s.registered = true }
            if s.url != nil, s.registered, self?.state == .starting {
                self?.goLive(s)
            }
        }
        do {
            try tunnel.run()
            s.tunnelProcess = tunnel
        } catch {
            fail(s, "Could not start cloudflared", detail: error.localizedDescription)
        }
    }

    /// Pipes a process's output through a line buffer into `onLine` (main thread),
    /// and cleans up if the process dies while we still care about it.
    private func attach(process: Process, to s: ShareSession, tag: String,
                        onLine: @escaping (String) -> Void) {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                for line in buffer.feed(text) where !line.isEmpty {
                    s.remember(line)
                    onLine(line)
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.session === s, !s.stopRequested else { return }
                self.fail(s, "Sharing stopped: the \(tag) process exited",
                          detail: s.logTail.suffix(8).joined(separator: "\n"))
            }
        }
    }

    private func goLive(_ s: ShareSession) {
        guard session === s else { return }
        state = .live
        rebuildUI()
        showQRWindow()
    }

    private func fail(_ s: ShareSession, _ title: String, detail: String) {
        guard session === s else { return }
        s.terminateProcesses()
        session = nil
        state = .idle
        rebuildUI()
        alert(title, detail)
    }

    private func findCloudflared() -> String? {
        var candidates = ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/cloudflared" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: QR window

    @objc private func showQRWindow() {
        guard let s = session, let url = s.url else { return }
        qrWindow?.close()

        let qr = NSImageView()
        qr.image = qrImage(for: url, sideLength: 260)
        qr.translatesAutoresizingMaskIntoConstraints = false
        qr.widthAnchor.constraint(equalToConstant: 260).isActive = true
        qr.heightAnchor.constraint(equalToConstant: 260).isActive = true

        let urlField = selectableLabel(url, size: 13, weight: .semibold)
        let pwField = selectableLabel("Password: \(s.password)", size: 13, weight: .regular)
        let foldersField = selectableLabel(
            "Sharing: " + s.folders.map(\.lastPathComponent).joined(separator: ", "),
            size: 11, weight: .regular)
        foldersField.textColor = .secondaryLabelColor
        let hint = selectableLabel("Scan with the phone camera, sign in with any username.",
                                   size: 11, weight: .regular)
        hint.textColor = .secondaryLabelColor

        let copyButton = NSButton(title: "Copy Link", target: self, action: #selector(copyLink))
        copyButton.bezelStyle = .rounded
        let stopButton = NSButton(title: "Stop Sharing", target: self, action: #selector(stopSharing))
        stopButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [copyButton, stopButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [qr, urlField, pwField, foldersField, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        let window = NSWindow(contentRect: .zero,
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "ftransfer — scan on your phone"
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.setContentSize(stack.fittingSize)
        window.center()
        qrWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func selectableLabel(_ text: String, size: CGFloat,
                                 weight: NSFont.Weight) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.isSelectable = true
        f.font = .systemFont(ofSize: size, weight: weight)
        f.lineBreakMode = .byTruncatingMiddle
        f.maximumNumberOfLines = 1
        return f
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
