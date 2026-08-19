// In-process HTTP file server — the Swift twin of server.py.
//
// Renders byte-identical HTML to the Python server (tests/parity.sh checks
// this), which is what lets the app ship with no Python dependency at all:
// no /usr/bin/python3, so no Xcode Command Line Tools, so no admin rights.
//
// Binds 127.0.0.1 only; the Cloudflare tunnel is the sole way in.

import Foundation
import Network

// MARK: - Shared UI strings (must match server.py exactly)

enum UI {
    static let favicon = "data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 "
        + "viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>📦</text></svg>"

    static let css = """

:root { color-scheme: light dark; }
* { box-sizing: border-box; }
body { margin: 0 auto; max-width: 640px; padding: 20px 14px 40px;
  font: 16px/1.45 -apple-system, system-ui, "Segoe UI", Roboto, sans-serif;
  background: Canvas; color: CanvasText; }
header { margin: 4px 2px 14px; }
h1 { font-size: 22px; margin: 0 0 2px; }
.crumb { font-size: 13px; opacity: .55; overflow-wrap: anywhere; }
ul.files { list-style: none; margin: 0; padding: 0; border: 1px solid #8883;
  border-radius: 14px; overflow: hidden; background: rgba(127,127,127,.05); }
li { display: flex; align-items: center; border-top: 1px solid #8883; }
li:first-child { border-top: none; }
a.item { flex: 1; min-width: 0; display: flex; align-items: center; gap: 12px;
  padding: 12px 14px; color: inherit; text-decoration: none;
  -webkit-tap-highlight-color: rgba(127,127,127,.15); }
.ic { font-size: 22px; flex: none; }
.nm { overflow-wrap: anywhere; }
.meta { display: block; font-size: 12.5px; opacity: .55; margin-top: 1px; }
a.dl { flex: none; margin-right: 10px; padding: 8px 14px; border: 1px solid #8885;
  border-radius: 10px; text-decoration: none; color: inherit; font-size: 15px; }
a.dl:active, a.item:active { background: rgba(127,127,127,.12); }
.empty { padding: 34px 16px; text-align: center; opacity: .6; }
footer { margin-top: 14px; font-size: 12.5px; opacity: .45; text-align: center; }
.toolbar { display: flex; gap: 8px; margin: 0 0 12px; }
.tbtn { padding: 8px 14px; border: 1px solid #8885; border-radius: 10px; background: none;
  color: inherit; font: inherit; font-size: 14px; text-decoration: none; cursor: pointer; }
.tbtn:active { background: rgba(127,127,127,.12); }
.ck { display: none; flex: none; width: 22px; height: 22px; border: 2px solid #8887;
  border-radius: 50%; position: relative; }
body.selecting .ck { display: inline-block; }
body.selecting a.dl { display: none; }
li.sel { background: rgba(10,132,255,.10); }
li.sel .ck { background: #0a84ff; border-color: #0a84ff; }
li.sel .ck::after { content: "✓"; position: absolute; inset: 0; color: #fff;
  text-align: center; line-height: 22px; font-size: 14px; font-weight: 700; }
#bar { display: none; position: fixed; left: 0; right: 0; bottom: 0; gap: 10px;
  align-items: center; padding: 12px 16px calc(12px + env(safe-area-inset-bottom));
  background: Canvas; border-top: 1px solid #8884; }
body.selecting #bar { display: flex; }
body.selecting { padding-bottom: 90px; }
#cnt { flex: 1; opacity: .7; font-size: 14px; }
.primary { background: #0a84ff; color: #fff; border: none; padding: 10px 18px;
  border-radius: 12px; font: inherit; font-size: 15px; font-weight: 600; cursor: pointer; }
.primary:disabled { opacity: .4; }

"""

    static let js = """

(function () {
  var selbtn = document.getElementById('selbtn');
  if (!selbtn) return;
  var cnt = document.getElementById('cnt');
  var dl = document.getElementById('dlsel');
  var picked = {};
  var n = 0;
  function upd() {
    cnt.textContent = n + ' selected';
    dl.disabled = n === 0;
  }
  selbtn.addEventListener('click', function () {
    document.body.classList.add('selecting');
    upd();
  });
  document.getElementById('cancel').addEventListener('click', function () {
    document.body.classList.remove('selecting');
    picked = {}; n = 0;
    document.querySelectorAll('li.sel').forEach(function (li) {
      li.classList.remove('sel');
    });
  });
  document.querySelectorAll('li[data-name]').forEach(function (li) {
    li.querySelector('a.item').addEventListener('click', function (e) {
      if (!document.body.classList.contains('selecting')) return;
      e.preventDefault();
      var name = li.getAttribute('data-name');
      if (picked[name]) { delete picked[name]; n--; li.classList.remove('sel'); }
      else { picked[name] = 1; n++; li.classList.add('sel'); }
      upd();
    });
  });
  dl.addEventListener('click', function () {
    if (!n) return;
    var parts = [];
    for (var k in picked) parts.push('files=' + encodeURIComponent(k));
    window.location.href = '?zip=1&' + parts.join('&');
  });
})();

"""

    static let toolbar = """
<div class="toolbar">
  <button class="tbtn" id="selbtn" type="button">Select</button>
  <a class="tbtn" href="?zip=1">⬇ Download all (zip)</a>
</div>
"""
        .trimmingCharacters(in: .newlines)

    static let selectBar = """
<div id="bar">
  <span id="cnt">0 selected</span>
  <button class="tbtn" id="cancel" type="button">Cancel</button>
  <button class="primary" id="dlsel" type="button" disabled>Download</button>
</div>
"""
        .trimmingCharacters(in: .newlines)

    static func page(title: String, crumb: String, body: String,
                     footer: String, toolbar: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(title))</title>
        <link rel="icon" href="\(favicon)">
        <style>\(css)</style>
        <header>
          <h1>📦 \(esc(title))</h1>
          <div class="crumb">\(esc(crumb))</div>
        </header>
        \(toolbar)
        \(body)
        <footer>\(esc(footer))</footer>
        \(selectBar)
        <script>\(js)</script>
        </html>
        """
    }
}

/// html.escape(s, quote=True) from Python.
func esc(_ s: String) -> String {
    var out = s.replacingOccurrences(of: "&", with: "&amp;")
    out = out.replacingOccurrences(of: "<", with: "&lt;")
    out = out.replacingOccurrences(of: ">", with: "&gt;")
    out = out.replacingOccurrences(of: "\"", with: "&quot;")
    return out.replacingOccurrences(of: "'", with: "&#x27;")
}

/// urllib.parse.quote(s) — safe='/', uppercase hex, ASCII unreserved only.
func urlQuote(_ s: String) -> String {
    let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~/")
    return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
}

func humanSize(_ n: UInt64) -> String {
    if n < 1024 { return "\(n) B" }
    var x = Double(n)
    for unit in ["KB", "MB", "GB", "TB"] {
        x /= 1024
        if x < 1024 || unit == "TB" { return String(format: "%.1f %@", x, unit) }
    }
    return "\(n) B"
}

private let iconTable: [(Set<String>, String)] = [
    (["png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "bmp", "tif", "tiff"], "🖼️"),
    (["mp4", "mov", "mkv", "avi", "webm", "m4v"], "🎬"),
    (["mp3", "m4a", "wav", "flac", "aac", "ogg"], "🎵"),
    (["pdf"], "📕"),
    (["zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso"], "🗜️"),
    (["txt", "md", "log", "csv", "json", "xml", "yaml", "yml"], "📝"),
]

func iconFor(_ name: String, isDir: Bool) -> String {
    if isDir { return "📁" }
    guard name.contains("."), let ext = name.split(separator: ".").last else { return "📄" }
    let lower = ext.lowercased()
    for (exts, icon) in iconTable where exts.contains(lower) { return icon }
    return "📄"
}

// MARK: - Server

final class FileServer {
    struct Root {
        let name: String
        let path: String   // realpath, no trailing slash
    }

    private enum Target {
        case index                 // virtual root of a multi-folder share
        case path(String)
        case notFound
    }

    let roots: [Root]
    let password: String
    private let title: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.sagnik.ftransfer.server")
    private let mimeTypes: [String: String] = [
        "html": "text/html", "htm": "text/html", "txt": "text/plain", "md": "text/markdown",
        "css": "text/css", "js": "text/javascript", "json": "application/json",
        "xml": "application/xml", "csv": "text/csv", "pdf": "application/pdf",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "heic": "image/heic", "svg": "image/svg+xml", "bmp": "image/bmp",
        "mp4": "video/mp4", "mov": "video/quicktime", "m4v": "video/x-m4v",
        "webm": "video/webm", "mkv": "video/x-matroska",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "wav": "audio/wav", "aac": "audio/aac",
        "flac": "audio/flac", "ogg": "audio/ogg",
        "zip": "application/zip", "gz": "application/gzip", "dmg": "application/x-apple-diskimage",
    ]

    init(folders: [URL], password: String) {
        var used = Set<String>()
        var made: [Root] = []
        for folder in folders {
            let real = (folder.resolvingSymlinksInPath().path as NSString)
                .standardizingPath
            var name = (real as NSString).lastPathComponent
            while name.hasPrefix(".") { name.removeFirst() }
            if name.isEmpty { name = "folder" }
            var candidate = name
            var i = 2
            while used.contains(candidate) {
                candidate = "\(name) (\(i))"
                i += 1
            }
            used.insert(candidate)
            made.append(Root(name: candidate, path: real))
        }
        self.roots = made
        self.password = password
        self.title = made.count == 1 ? made[0].name : "Shared folders"
    }

    /// Binds to 127.0.0.1 on an ephemeral port and returns it.
    func start() throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error), .waiting(let error):
                failure = error
                ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: self?.queue ?? .global())
            self?.receive(conn, buffer: Data())
        }
        listener.start(queue: queue)

        if ready.wait(timeout: .now() + 10) == .timedOut {
            throw NSError(domain: "ftransfer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "server did not start in time"])
        }
        if let failure { throw failure }
        guard let port = listener.port?.rawValue else {
            throw NSError(domain: "ftransfer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "server has no port"])
        }
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: request cycle

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] chunk, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            if error != nil { conn.cancel(); return }

            if let headerEnd = Self.range(of: Data("\r\n\r\n".utf8), in: buffer) {
                let head = String(decoding: buffer[..<headerEnd.lowerBound])
                self.handle(head: head, conn: conn)
                return
            }
            if complete || buffer.count > 128 * 1024 { conn.cancel(); return }
            self.receive(conn, buffer: buffer)
        }
    }

    private func handle(head: String, conn: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return respondError(conn, 400, "Bad Request", isHead: false) }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        let isHead = method == "HEAD"
        guard method == "GET" || isHead else {
            return respondError(conn, 405, "Method Not Allowed", isHead: false)
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        guard authorized(headers["authorization"]) else {
            let body = Data("Password required.\n".utf8)
            return send(conn, status: "401 Unauthorized",
                        headers: [("WWW-Authenticate", "Basic realm=\"ftransfer\", charset=\"UTF-8\""),
                                  ("Content-Type", "text/plain; charset=utf-8"),
                                  ("Content-Length", "\(body.count)")],
                        body: isHead ? nil : StaticChunk(body))
        }

        // split path?query
        let rawPath: String
        let rawQuery: String
        if let q = target.firstIndex(of: "?") {
            rawPath = String(target[..<q])
            rawQuery = String(target[target.index(after: q)...])
        } else {
            rawPath = target
            rawQuery = ""
        }
        let query = Self.parseQuery(rawQuery)
        let wantZip = query["zip"]?.contains("1") == true
        let selected = query["files"] ?? []

        switch resolve(rawPath) {
        case .notFound:
            respondError(conn, 404, "Not found", isHead: isHead)

        case .index:
            if wantZip {
                sendZip(conn, name: "ftransfer.zip",
                        entries: zipEntriesForIndex(selected), isHead: isHead)
            } else {
                sendHTML(conn, indexPage(), isHead: isHead)
            }

        case .path(let fsPath):
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fsPath, isDirectory: &isDir) else {
                return respondError(conn, 404, "Not found", isHead: isHead)
            }
            if isDir.boolValue {
                guard rawPath.hasSuffix("/") else {
                    var location = rawPath + "/"
                    if !rawQuery.isEmpty { location += "?" + rawQuery }
                    return send(conn, status: "301 Moved Permanently",
                                headers: [("Location", location), ("Content-Length", "0")],
                                body: nil)
                }
                if wantZip {
                    let base = (fsPath as NSString).lastPathComponent
                    sendZip(conn, name: (base.isEmpty ? "files" : base) + ".zip",
                            entries: zipEntriesForDir(fsPath, selected), isHead: isHead)
                } else {
                    sendHTML(conn, listingPage(fsPath, urlPath: rawPath), isHead: isHead)
                }
            } else {
                sendFile(conn, path: fsPath, rangeHeader: headers["range"],
                         forceDownload: query["dl"]?.contains("1") == true, isHead: isHead)
            }
        }
    }

    private func authorized(_ header: String?) -> Bool {
        guard let header, header.hasPrefix("Basic ") else { return false }
        let encoded = String(header.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        guard let data = Data(base64Encoded: encoded),
              let decoded = String(data: data, encoding: .utf8) else { return false }
        let supplied = decoded.firstIndex(of: ":").map { String(decoded[decoded.index(after: $0)...]) } ?? ""
        // constant-time compare
        let a = Array(supplied.utf8), b = Array(password.utf8)
        var diff = a.count ^ b.count
        for i in 0..<max(a.count, b.count) {
            diff |= Int(i < a.count ? a[i] : 0) ^ Int(i < b.count ? b[i] : 0)
        }
        return diff == 0
    }

    // MARK: path resolution

    private func resolve(_ urlPath: String) -> Target {
        let decoded = urlPath.removingPercentEncoding ?? urlPath
        var parts = decoded.split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }
        // no traversal, no dotfiles — ever
        if parts.contains(where: { $0 == ".." || $0.hasPrefix(".") }) { return .notFound }

        let base: String
        if roots.count == 1 {
            base = roots[0].path
        } else {
            if parts.isEmpty { return .index }
            guard let root = roots.first(where: { $0.name == parts[0] }) else { return .notFound }
            base = root.path
            parts.removeFirst()
        }
        let joined = parts.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
        let real = URL(fileURLWithPath: joined).resolvingSymlinksInPath().path
        guard real == base || real.hasPrefix(base + "/") else { return .notFound }
        return .path(real)
    }

    // MARK: zip entry collection

    /// Every regular file under `top`, dotfiles and symlinks skipped.
    ///
    /// Uses relative subpaths rather than trimming absolute ones: on macOS a
    /// path under /var resolves to /private/var, so prefix arithmetic against
    /// the enumerated URLs silently matches nothing.
    private func walk(_ top: String, prefix: String) -> [ZipEntry] {
        let fm = FileManager.default
        guard let subpaths = try? fm.subpathsOfDirectory(atPath: top) else { return [] }
        var out: [ZipEntry] = []
        for rel in subpaths {
            if rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            let full = (top as NSString).appendingPathComponent(rel)
            // attributesOfItem does not follow symlinks, so links report as links
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  (attrs[.type] as? FileAttributeType) == .typeRegular else { continue }
            out.append(ZipEntry(arcname: prefix.isEmpty ? rel : "\(prefix)/\(rel)", path: full))
        }
        return out.sorted { $0.arcname < $1.arcname }
    }

    private func zipEntriesForDir(_ dir: String, _ onlyNames: [String]) -> [ZipEntry] {
        guard !onlyNames.isEmpty else { return walk(dir, prefix: "") }
        var out: [ZipEntry] = []
        for raw in onlyNames {
            let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if name.isEmpty || name == ".." || name.hasPrefix(".") || name.contains("/") { continue }
            let full = URL(fileURLWithPath: (dir as NSString).appendingPathComponent(name))
                .resolvingSymlinksInPath().path
            guard full == dir || full.hasPrefix(dir + "/") else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                out += walk(full, prefix: name)
            } else {
                out.append(ZipEntry(arcname: name, path: full))
            }
        }
        return out
    }

    private func zipEntriesForIndex(_ onlyNames: [String]) -> [ZipEntry] {
        let wanted = onlyNames.isEmpty ? nil : Set(onlyNames)
        var out: [ZipEntry] = []
        for root in roots {
            if let wanted, !wanted.contains(root.name) { continue }
            out += walk(root.path, prefix: root.name)
        }
        return out
    }

    // MARK: page rendering

    private func indexPage() -> String {
        var rows: [String] = []
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            rows.append("""
            <li data-name="\(esc(root.name))"><a class="item" href="/\(urlQuote(root.name))/">\
            <span class="ck"></span><span class="ic">📁</span>\
            <span class="nm">\(esc(root.name))<span class="meta">shared folder</span></span>\
            </a></li>
            """)
        }
        return UI.page(title: title, crumb: "/",
                       body: "<ul class=\"files\">\(rows.joined())</ul>",
                       footer: "ftransfer · \(rows.count) shared folders",
                       toolbar: rows.isEmpty ? "" : UI.toolbar)
    }

    private func listingPage(_ dir: String, urlPath: String) -> String {
        struct Entry {
            let isDir: Bool, name: String, size: UInt64, modified: Date
        }
        let fm = FileManager.default
        var entries: [Entry] = []
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            if name.hasPrefix(".") { continue }
            let full = (dir as NSString).appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: full) else { continue }
            let type = attrs[.type] as? FileAttributeType
            entries.append(Entry(isDir: type == .typeDirectory,
                                 name: name,
                                 size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
                                 modified: (attrs[.modificationDate] as? Date) ?? Date()))
        }
        entries.sort {
            $0.isDir != $1.isDir ? $0.isDir
                                 : $0.name.lowercased() < $1.name.lowercased()
        }

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "MMM dd, HH:mm"

        var rows: [String] = []
        if urlPath != "/" {
            rows.append("<li><a class=\"item\" href=\"../\"><span class=\"ic\">⬆️</span>"
                      + "<span class=\"nm\">Up</span></a></li>")
        }
        for e in entries {
            let quoted = urlQuote(e.name)
            let meta = e.isDir ? "folder"
                               : "\(humanSize(e.size)) · \(stamp.string(from: e.modified))"
            let href = e.isDir ? quoted + "/" : quoted
            let dlBtn = e.isDir ? ""
                                : "<a class=\"dl\" href=\"\(quoted)?dl=1\" download>↓</a>"
            rows.append("""
            <li data-name="\(esc(e.name))"><a class="item" href="\(href)">\
            <span class="ck"></span>\
            <span class="ic">\(iconFor(e.name, isDir: e.isDir))</span>\
            <span class="nm">\(esc(e.name))<span class="meta">\(meta)</span></span>\
            </a>\(dlBtn)</li>
            """)
        }

        let body: String
        if rows.isEmpty {
            body = "<ul class=\"files\"><li><div class=\"empty\">Nothing here yet.<br>"
                 + "Drop files into the shared folder on the Mac, then refresh.</div></li></ul>"
        } else {
            body = "<ul class=\"files\">\(rows.joined())</ul>"
        }
        let n = entries.count
        return UI.page(title: title,
                       crumb: urlPath.removingPercentEncoding ?? urlPath,
                       body: body,
                       footer: "ftransfer · \(n) item\(n != 1 ? "s" : "") "
                             + "· tap a name to preview, ↓ to download",
                       toolbar: entries.isEmpty ? "" : UI.toolbar)
    }

    // MARK: responses

    private func sendHTML(_ conn: NWConnection, _ html: String, isHead: Bool) {
        let body = Data(html.utf8)
        send(conn, status: "200 OK",
             headers: [("Content-Type", "text/html; charset=utf-8"),
                       ("Content-Length", "\(body.count)"),
                       ("Cache-Control", "no-store")],
             body: isHead ? nil : StaticChunk(body))
    }

    private func respondError(_ conn: NWConnection, _ code: Int, _ text: String, isHead: Bool) {
        let body = Data("\(code) \(text)\n".utf8)
        send(conn, status: "\(code) \(text)",
             headers: [("Content-Type", "text/plain; charset=utf-8"),
                       ("Content-Length", "\(body.count)")],
             body: isHead ? nil : StaticChunk(body))
    }

    private func sendFile(_ conn: NWConnection, path: String, rangeHeader: String?,
                          forceDownload: Bool, isHead: Bool) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            return respondError(conn, 404, "Not found", isHead: isHead)
        }
        let ext = path.contains(".") ? String(path.split(separator: ".").last ?? "").lowercased() : ""
        var ctype = mimeTypes[ext] ?? "application/octet-stream"
        if ctype.hasPrefix("text/") || ctype == "application/json" || ctype == "image/svg+xml" {
            ctype += "; charset=utf-8"
        }

        var start: UInt64 = 0
        var end = size == 0 ? 0 : size - 1
        var status = "200 OK"
        var extra: [(String, String)] = []

        if let raw = rangeHeader, let parsed = Self.parseRange(raw, size: size) {
            switch parsed {
            case .unsatisfiable:
                return send(conn, status: "416 Range Not Satisfiable",
                            headers: [("Content-Range", "bytes */\(size)"), ("Content-Length", "0")],
                            body: nil)
            case .range(let s, let e):
                start = s; end = e
                status = "206 Partial Content"
                extra.append(("Content-Range", "bytes \(s)-\(e)/\(size)"))
            }
        }

        let length = size == 0 ? 0 : Int(end - start + 1)
        var headers: [(String, String)] = [
            ("Content-Type", ctype),
            ("Content-Length", "\(length)"),
            ("Accept-Ranges", "bytes"),
            ("X-Content-Type-Options", "nosniff"),
        ]
        headers += extra
        if forceDownload {
            let name = urlQuote((path as NSString).lastPathComponent)
            headers.append(("Content-Disposition", "attachment; filename*=UTF-8''\(name)"))
        }
        let body: ChunkProducer? = (isHead || length == 0)
            ? nil : FileChunks(path: path, offset: start, length: length)
        send(conn, status: status, headers: headers, body: body)
    }

    private func sendZip(_ conn: NWConnection, name: String,
                         entries: [ZipEntry], isHead: Bool) {
        // Length is unknown up front, so the body is close-delimited.
        send(conn, status: "200 OK",
             headers: [("Content-Type", "application/zip"),
                       ("Content-Disposition", "attachment; filename*=UTF-8''\(urlQuote(name))"),
                       ("Cache-Control", "no-store")],
             body: isHead ? nil : ZipChunks(entries: entries))
    }

    /// Writes the status line + headers, then pumps the body with backpressure
    /// (one chunk per send completion) so huge files never sit in memory.
    private func send(_ conn: NWConnection, status: String,
                      headers: [(String, String)], body: ChunkProducer?) {
        var head = "HTTP/1.1 \(status)\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Server: ftransfer\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil else { conn.cancel(); return }
            guard let body else { self?.finish(conn); return }
            self?.pump(conn, body)
        })
    }

    private func pump(_ conn: NWConnection, _ producer: ChunkProducer) {
        guard let chunk = producer.next() else { return finish(conn) }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil else { conn.cancel(); return }
            self?.pump(conn, producer)
        })
    }

    private func finish(_ conn: NWConnection) {
        conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    // MARK: parsing helpers

    private enum ParsedRange {
        case range(UInt64, UInt64)
        case unsatisfiable
    }

    private static func parseRange(_ header: String, size: UInt64) -> ParsedRange? {
        let spec = header.trimmingCharacters(in: .whitespaces)
        guard spec.hasPrefix("bytes="), size > 0 else { return nil }
        let body = String(spec.dropFirst(6))
        guard !body.contains(","), let dash = body.firstIndex(of: "-") else { return nil }
        let firstPart = String(body[..<dash])
        let lastPart = String(body[body.index(after: dash)...])
        if firstPart.isEmpty && lastPart.isEmpty { return nil }

        if firstPart.isEmpty {
            guard let suffix = UInt64(lastPart) else { return nil }
            let start = suffix >= size ? 0 : size - suffix
            return .range(start, size - 1)
        }
        guard let start = UInt64(firstPart) else { return nil }
        if start >= size { return .unsatisfiable }
        var end = size - 1
        if !lastPart.isEmpty {
            guard let requested = UInt64(lastPart) else { return nil }
            end = min(requested, size - 1)
        }
        if end < start { return .unsatisfiable }
        return .range(start, end)
    }

    private static func parseQuery(_ raw: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for pair in raw.split(separator: "&") {
            let bits = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let keyRaw = bits.first, !keyRaw.isEmpty else { continue }
            let key = String(keyRaw).replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding ?? String(keyRaw)
            let value = bits.count > 1
                ? (String(bits[1]).replacingOccurrences(of: "+", with: " ")
                    .removingPercentEncoding ?? String(bits[1]))
                : ""
            guard !value.isEmpty else { continue }
            out[key, default: []].append(value)
        }
        return out
    }

    private static func range(of needle: Data, in haystack: Data) -> Range<Data.Index>? {
        haystack.range(of: needle)
    }
}

/// A body already fully in memory.
struct StaticChunk: ChunkProducer {
    private var data: Data?
    init(_ data: Data) { self.data = data }
    private final class Box { var sent = false }
    private let box = Box()
    func next() -> Data? {
        guard !box.sent, let data else { return nil }
        box.sent = true
        return data
    }
}

private extension String {
    init(decoding slice: Data.SubSequence) {
        self = String(data: Data(slice), encoding: .utf8) ?? ""
    }
}
