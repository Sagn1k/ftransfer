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

/// QR code with a small 📦 badge in the middle. Correction level H tolerates
/// the badge covering the center modules.
private func qrImage(for string: String, sideLength: CGFloat) -> NSImage? {
    guard let data = string.data(using: .ascii),
          let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("H", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    let scale = sideLength / output.extent.width
    let scaled = output.samplingNearest()
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let rep = NSCIImageRep(ciImage: scaled)
    let plain = NSImage(size: rep.size)
    plain.addRepresentation(rep)

    return NSImage(size: rep.size, flipped: false) { rect in
        plain.draw(in: rect)
        let badgeSide = rect.width * 0.17
        let badge = NSRect(x: rect.midX - badgeSide / 2, y: rect.midY - badgeSide / 2,
                           width: badgeSide, height: badgeSide)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: badge, xRadius: badgeSide * 0.24,
                     yRadius: badgeSide * 0.24).fill()
        let emoji = "📦" as NSString
        let attrs: [NSAttributedString.Key: Any] =
            [.font: NSFont.systemFont(ofSize: badgeSide * 0.58)]
        let textSize = emoji.size(withAttributes: attrs)
        emoji.draw(at: NSPoint(x: rect.midX - textSize.width / 2,
                               y: rect.midY - textSize.height / 2),
                   withAttributes: attrs)
        return true
    }
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

    var folderNames: String {
        folders.map(\.lastPathComponent).joined(separator: ", ")
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
    private var shareWindow: NSWindow?

    private let lastFolderKey = "lastSharedFolder"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        rebuildUI()
        // FT_PREVIEW=1: render the QR window with fake data (UI development).
        if ProcessInfo.processInfo.environment["FT_PREVIEW"] != nil {
            let s = ShareSession(folders: [
                URL(fileURLWithPath: NSHomeDirectory() + "/Documents"),
                URL(fileURLWithPath: NSHomeDirectory() + "/Downloads"),
            ])
            s.url = "https://impacts-leaves-shipping-pst.trycloudflare.com"
            session = s
            state = .live
            rebuildUI()
            showQRWindow()
            if let n = shareWindow?.windowNumber {
                FileHandle.standardOutput.write(Data("FT_PREVIEW_WINDOW \(n)\n".utf8))
            }
            // FT_PREVIEW_OUT=/path.png: render the window content to a PNG
            // (self-render, needs no screen-recording permission) and exit.
            if let out = ProcessInfo.processInfo.environment["FT_PREVIEW_OUT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    if let view = self?.shareWindow?.contentView {
                        view.layoutSubtreeIfNeeded()
                        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                            view.cacheDisplay(in: view.bounds, to: rep)
                            if let png = rep.representation(using: .png, properties: [:]) {
                                try? png.write(to: URL(fileURLWithPath: out))
                            }
                        }
                    }
                    NSApp.terminate(nil)
                }
            }
            return
        }
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
        case .starting: shareWindow?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.terminateProcesses()
    }

    // MARK: Menu bar

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
        shareWindow?.close()
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

    @objc private func copyLinkTapped(_ sender: NSButton) {
        copyLink()
        flashCopied(sender)
    }

    @objc private func copyPasswordTapped(_ sender: NSButton) {
        copyPassword()
        flashCopied(sender)
    }

    private func flashCopied(_ button: NSButton) {
        let original = button.image
        button.image = NSImage(systemSymbolName: "checkmark",
                               accessibilityDescription: "Copied")
        button.contentTintColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak button] in
            button?.image = original
            button?.contentTintColor = .secondaryLabelColor
        }
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
        showConnectingWindow()

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
        shareWindow?.close()
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

    // MARK: Share window (connecting + QR)

    private func presentShareWindow(_ content: NSView) {
        let window: NSWindow
        if let existing = shareWindow {
            window = existing
        } else {
            window = NSWindow(contentRect: .zero,
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.level = .floating
            shareWindow = window
        }
        window.title = "ftransfer"
        window.contentView = content
        window.setContentSize(content.fittingSize)
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func showConnectingWindow() {
        guard let s = session else { return }

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)

        let title = label("Starting secure tunnel…", size: 15, weight: .semibold)
        let sub = label("Sharing \(s.folderNames)", size: 12, weight: .regular,
                        color: .secondaryLabelColor)
        sub.lineBreakMode = .byTruncatingMiddle

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(stopSharing))
        cancel.bezelStyle = .rounded

        let stack = NSStackView(views: [spinner, title, sub, cancel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(18, after: sub)
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 60, bottom: 26, right: 60)

        presentShareWindow(stack)
    }

    @objc private func showQRWindow() {
        guard let s = session, let url = s.url else { return }

        // --- header: live status ------------------------------------------
        let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill",
                                             accessibilityDescription: "live")!)
        dot.contentTintColor = .systemGreen
        dot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)

        let headline = label("Ready — scan with your phone", size: 16, weight: .bold)
        let header = NSStackView(views: [dot, headline])
        header.orientation = .horizontal
        header.spacing = 7

        let folders = label("Sharing \(s.folderNames)", size: 12, weight: .regular,
                            color: .secondaryLabelColor)
        folders.lineBreakMode = .byTruncatingMiddle

        // --- QR on a white card (scans well in dark mode too) --------------
        let qr = NSImageView()
        qr.image = qrImage(for: url, sideLength: 480)  // rendered @2x, shown at 240
        qr.imageScaling = .scaleProportionallyUpOrDown
        qr.widthAnchor.constraint(equalToConstant: 240).isActive = true
        qr.heightAnchor.constraint(equalToConstant: 240).isActive = true

        let card = NSStackView(views: [qr])
        card.orientation = .vertical
        card.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 18
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.22
        card.layer?.shadowRadius = 14
        card.layer?.shadowOffset = CGSize(width: 0, height: -3)

        // --- link row -------------------------------------------------------
        let linkText = label(url.replacingOccurrences(of: "https://", with: ""),
                             size: 13, weight: .medium)
        linkText.lineBreakMode = .byTruncatingMiddle
        let linkRow = capsule(views: [linkText,
                                      iconButton("doc.on.doc", #selector(copyLinkTapped(_:)),
                                                 help: "Copy link")])

        // --- password row ----------------------------------------------------
        let pwTitle = label("PASSWORD", size: 10, weight: .semibold,
                            color: .secondaryLabelColor)
        let pwValue = NSTextField(labelWithString: "")
        pwValue.isSelectable = true
        pwValue.attributedStringValue = NSAttributedString(
            string: s.password,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 22, weight: .semibold),
                         .kern: 2.5])
        let pwText = NSStackView(views: [pwTitle, pwValue])
        pwText.orientation = .vertical
        pwText.alignment = .leading
        pwText.spacing = 1
        let pwRow = capsule(views: [pwText,
                                    iconButton("doc.on.doc", #selector(copyPasswordTapped(_:)),
                                               help: "Copy password")],
                            height: 58)

        let hint = label("Any username works — just enter the password.",
                         size: 11, weight: .regular, color: .tertiaryLabelColor)

        // --- buttons ---------------------------------------------------------
        let openBtn = NSButton(title: "Open Folder", target: self, action: #selector(openFolders))
        openBtn.bezelStyle = .rounded
        let stopBtn = NSButton(title: "Stop Sharing", target: self, action: #selector(stopSharing))
        stopBtn.bezelStyle = .rounded
        stopBtn.hasDestructiveAction = true
        let buttons = NSStackView(views: [openBtn, stopBtn])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        // --- assemble --------------------------------------------------------
        let stack = NSStackView(views: [header, folders, card, linkRow, pwRow, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(4, after: header)
        stack.setCustomSpacing(16, after: folders)
        stack.setCustomSpacing(16, after: card)
        stack.setCustomSpacing(14, after: hint)
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 30, bottom: 22, right: 30)

        for row in [linkRow, pwRow] {
            row.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
        }

        presentShareWindow(stack)
    }

    // MARK: small view builders

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       color: NSColor = .labelColor) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.isSelectable = true
        f.font = .systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.maximumNumberOfLines = 1
        return f
    }

    private func capsule(views: [NSView], height: CGFloat = 38) -> NSStackView {
        var arranged = views
        if arranged.count >= 2 {
            // flexible spacer so the trailing button hugs the right edge
            let spacer = NSView()
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            arranged.insert(spacer, at: arranged.count - 1)
        }
        let row = NSStackView(views: arranged)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 10)
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.14).cgColor
        row.layer?.cornerRadius = 12
        row.heightAnchor.constraint(equalToConstant: height).isActive = true
        return row
    }

    private func iconButton(_ symbol: String, _ action: Selector, help: String) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol,
                                        accessibilityDescription: help)!,
                         target: self, action: action)
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = help
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        return b
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
