#!/usr/bin/env python3
"""ftransfer — share one or more folders over HTTP with Basic Auth.

Stdlib only, no dependencies. Meant to sit behind a Cloudflare quick tunnel
(see start.sh), but works standalone too:

    python3 server.py ~/Downloads ~/Desktop --port 8420 --password hunter2

With multiple folders, the root URL shows each folder by name.
"""

import argparse
import base64
import hmac
import mimetypes
import os
import re
import secrets
import sys
import time
import urllib.parse
import zipfile
from html import escape
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CHUNK = 256 * 1024
# no 0/O, 1/l/i — painless to type on a phone keyboard
PW_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"

ROOTS = []  # [(display_name, real_path)]
TITLE = "ftransfer"
PASSWORD = b""
INDEX = object()  # sentinel: the virtual root listing when sharing several folders

ICONS = [
    ({"png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "bmp", "tif", "tiff"}, "🖼️"),
    ({"mp4", "mov", "mkv", "avi", "webm", "m4v"}, "🎬"),
    ({"mp3", "m4a", "wav", "flac", "aac", "ogg"}, "🎵"),
    ({"pdf"}, "📕"),
    ({"zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso"}, "🗜️"),
    ({"txt", "md", "log", "csv", "json", "xml", "yaml", "yml"}, "📝"),
]

CSS = """
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

JS = """
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

TOOLBAR = """<div class="toolbar">
  <button class="tbtn" id="selbtn" type="button">Select</button>
  <a class="tbtn" href="?zip=1">⬇ Download all (zip)</a>
</div>"""

SELECT_BAR = """<div id="bar">
  <span id="cnt">0 selected</span>
  <button class="tbtn" id="cancel" type="button">Cancel</button>
  <button class="primary" id="dlsel" type="button" disabled>Download</button>
</div>"""

FAVICON = ('data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 '
           'viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>📦</text></svg>')


def icon_for(name, is_dir):
    if is_dir:
        return "📁"
    ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    for exts, ic in ICONS:
        if ext in exts:
            return ic
    return "📄"


def human_size(n):
    if n < 1024:
        return f"{n} B"
    x = float(n)
    for unit in ("KB", "MB", "GB", "TB"):
        x /= 1024
        if x < 1024 or unit == "TB":
            return f"{x:.1f} {unit}"


class _ZipStream:
    """Minimal unseekable write-through so ZipFile streams straight to the
    socket (zipfile then uses data descriptors instead of seeking back)."""

    def __init__(self, raw):
        self._raw = raw
        self._pos = 0

    def write(self, data):
        self._raw.write(data)
        self._pos += len(data)
        return len(data)

    def flush(self):
        self._raw.flush()

    def tell(self):
        return self._pos

    def seekable(self):
        return False


def _walk_files(top, prefix):
    """Yield (arcname, fs_path) for every regular file under top,
    skipping dotfiles and symlinks."""
    for root, dirs, files in os.walk(top):
        dirs[:] = [d for d in dirs
                   if not d.startswith(".") and not os.path.islink(os.path.join(root, d))]
        for fname in sorted(files):
            if fname.startswith("."):
                continue
            full = os.path.join(root, fname)
            if os.path.islink(full):
                continue
            rel = os.path.relpath(full, top)
            yield (f"{prefix}/{rel}" if prefix else rel), full


def _zip_entries_for_dir(fs_dir, only_names):
    """Files to zip from one directory: everything, or just the (top-level)
    names the client selected. Selected folders are included recursively."""
    if not only_names:
        yield from _walk_files(fs_dir, "")
        return
    for raw in only_names:
        name = raw.strip("/")
        if not name or name == ".." or name.startswith(".") or "/" in name:
            continue
        full = os.path.realpath(os.path.join(fs_dir, name))
        if full != fs_dir and not full.startswith(fs_dir + os.sep):
            continue
        if os.path.isfile(full):
            yield name, full
        elif os.path.isdir(full):
            yield from _walk_files(full, name)


def _zip_entries_for_index(only_names):
    """Files to zip from the virtual root of a multi-folder share."""
    wanted = set(only_names) if only_names else None
    for name, real_path in ROOTS:
        if wanted is not None and name not in wanted:
            continue
        yield from _walk_files(real_path, name)


def render_page(title, crumb, body, footer, toolbar=""):
    return f"""<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{escape(title)}</title>
<link rel="icon" href="{FAVICON}">
<style>{CSS}</style>
<header>
  <h1>📦 {escape(title)}</h1>
  <div class="crumb">{escape(crumb)}</div>
</header>
{toolbar}
{body}
<footer>{escape(footer)}</footer>
{SELECT_BAR}
<script>{JS}</script>
</html>"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ftransfer"

    # ---- plumbing -------------------------------------------------------

    def do_GET(self):
        try:
            self._handle()
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        except OSError:
            self.close_connection = True

    def do_HEAD(self):
        self.do_GET()

    def _authorized(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Basic "):
            return False
        try:
            decoded = base64.b64decode(auth[6:].strip()).decode("utf-8")
        except Exception:
            return False
        _, _, password = decoded.partition(":")
        return hmac.compare_digest(password.encode("utf-8"), PASSWORD)

    def _resolve(self, url_path):
        """Map a URL path to a real filesystem path inside a shared root,
        the INDEX sentinel (virtual root of a multi-folder share), or None."""
        path = urllib.parse.unquote(url_path)
        parts = [p for p in path.split("/") if p and p != "."]
        # no traversal, no dotfiles — ever
        if any(p == ".." or p.startswith(".") for p in parts):
            return None
        if len(ROOTS) == 1:
            base = ROOTS[0][1]
        else:
            if not parts:
                return INDEX
            base = next((rp for name, rp in ROOTS if name == parts[0]), None)
            if base is None:
                return None
            parts = parts[1:]
        real = os.path.realpath(os.path.join(base, *parts))
        if real != base and not real.startswith(base + os.sep):
            return None
        return real

    # ---- request handling ------------------------------------------------

    def _handle(self):
        if not self._authorized():
            body = b"Password required.\n"
            self.send_response(HTTPStatus.UNAUTHORIZED)
            self.send_header("WWW-Authenticate", 'Basic realm="ftransfer", charset="UTF-8"')
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
            return

        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        want_zip = query.get("zip") == ["1"]
        fs_path = self._resolve(parsed.path)
        if fs_path is None:
            return self.send_error(HTTPStatus.NOT_FOUND, "Not found")

        if fs_path is INDEX:
            if want_zip:
                return self._send_zip("ftransfer.zip",
                                      _zip_entries_for_index(query.get("files")))
            return self._send_index()

        if os.path.isdir(fs_path):
            if not parsed.path.endswith("/"):
                location = parsed.path + "/"
                if parsed.query:
                    location += "?" + parsed.query
                self.send_response(HTTPStatus.MOVED_PERMANENTLY)
                self.send_header("Location", location)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if want_zip:
                zip_name = (os.path.basename(fs_path.rstrip("/")) or "files") + ".zip"
                return self._send_zip(zip_name,
                                      _zip_entries_for_dir(fs_path, query.get("files")))
            return self._send_listing(fs_path, parsed.path)

        if os.path.isfile(fs_path):
            return self._send_file(fs_path, query.get("dl") == ["1"])

        return self.send_error(HTTPStatus.NOT_FOUND, "Not found")

    def _send_zip(self, zip_name, entries):
        """Stream a zip of (arcname, fs_path) entries. Length is unknown up
        front, so the body is close-delimited (no Content-Length)."""
        quoted = urllib.parse.quote(zip_name)
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/zip")
        self.send_header("Content-Disposition", f"attachment; filename*=UTF-8''{quoted}")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command == "HEAD":
            return
        # ZIP_STORED: shared files are mostly media that won't compress;
        # storing streams at disk speed instead of burning CPU.
        with zipfile.ZipFile(_ZipStream(self.wfile), "w",
                             zipfile.ZIP_STORED, allowZip64=True) as zf:
            for arcname, full in entries:
                try:
                    zf.write(full, arcname)
                except OSError:
                    continue

    def _send_html(self, page_bytes):
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page_bytes)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(page_bytes)

    def _send_index(self):
        rows = []
        for name, real_path in ROOTS:
            try:
                os.stat(real_path)
            except OSError:
                continue
            quoted = urllib.parse.quote(name)
            rows.append(
                f'<li data-name="{escape(name)}"><a class="item" href="/{quoted}/">'
                f'<span class="ck"></span><span class="ic">📁</span>'
                f'<span class="nm">{escape(name)}<span class="meta">shared folder</span></span>'
                f'</a></li>'
            )
        page = render_page(
            title=TITLE,
            crumb="/",
            body=f'<ul class="files">{"".join(rows)}</ul>',
            footer=f"ftransfer · {len(rows)} shared folders",
            toolbar=TOOLBAR if rows else "",
        ).encode("utf-8", "replace")
        self._send_html(page)

    def _send_listing(self, fs_dir, url_path):
        entries = []
        try:
            for de in os.scandir(fs_dir):
                if de.name.startswith("."):
                    continue
                try:
                    st = de.stat()
                    entries.append((de.is_dir(), de.name, st.st_size, st.st_mtime))
                except OSError:
                    continue
        except OSError:
            return self.send_error(HTTPStatus.INTERNAL_SERVER_ERROR, "Cannot read folder")

        entries.sort(key=lambda t: (not t[0], t[1].lower()))

        rows = []
        if url_path != "/":
            rows.append('<li><a class="item" href="../"><span class="ic">⬆️</span>'
                        '<span class="nm">Up</span></a></li>')
        for is_dir, name, size, mtime in entries:
            try:
                quoted = urllib.parse.quote(name)
            except UnicodeError:
                continue
            when = time.strftime("%b %d, %H:%M", time.localtime(mtime))
            meta = "folder" if is_dir else f"{human_size(size)} · {when}"
            href = quoted + "/" if is_dir else quoted
            dl_btn = ("" if is_dir
                      else f'<a class="dl" href="{quoted}?dl=1" download>↓</a>')
            rows.append(
                f'<li data-name="{escape(name)}"><a class="item" href="{href}">'
                f'<span class="ck"></span>'
                f'<span class="ic">{icon_for(name, is_dir)}</span>'
                f'<span class="nm">{escape(name)}<span class="meta">{meta}</span></span>'
                f'</a>{dl_btn}</li>'
            )

        if rows:
            body = f'<ul class="files">{"".join(rows)}</ul>'
        else:
            body = ('<ul class="files"><li><div class="empty">Nothing here yet.<br>'
                    'Drop files into the shared folder on the Mac, then refresh.</div></li></ul>')

        n = len(entries)
        page = render_page(
            title=TITLE,
            crumb=urllib.parse.unquote(url_path),
            body=body,
            footer=f"ftransfer · {n} item{'s' if n != 1 else ''} · tap a name to preview, ↓ to download",
            toolbar=TOOLBAR if entries else "",
        ).encode("utf-8", "replace")
        self._send_html(page)

    def _send_file(self, fs_path, force_download):
        st = os.stat(fs_path)
        size = st.st_size
        ctype = mimetypes.guess_type(fs_path)[0] or "application/octet-stream"

        start, end = 0, size - 1
        status = HTTPStatus.OK
        range_header = self.headers.get("Range")
        if range_header:
            m = re.match(r"bytes=(\d*)-(\d*)$", range_header.strip())
            if m and (m.group(1) or m.group(2)):
                if m.group(1):
                    start = int(m.group(1))
                    if m.group(2):
                        end = min(int(m.group(2)), size - 1)
                else:  # suffix range: last N bytes
                    start = max(0, size - int(m.group(2)))
                if start >= size:
                    self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                status = HTTPStatus.PARTIAL_CONTENT

        length = max(0, end - start + 1)
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("X-Content-Type-Options", "nosniff")
        if status == HTTPStatus.PARTIAL_CONTENT:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        if force_download:
            quoted_name = urllib.parse.quote(os.path.basename(fs_path))
            self.send_header("Content-Disposition", f"attachment; filename*=UTF-8''{quoted_name}")
        self.end_headers()

        if self.command == "HEAD":
            return
        with open(fs_path, "rb") as f:
            f.seek(start)
            remaining = length
            while remaining > 0:
                chunk = f.read(min(CHUNK, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)


def main():
    global ROOTS, TITLE, PASSWORD
    ap = argparse.ArgumentParser(description="Share folders over HTTP with Basic Auth.")
    ap.add_argument("directories", nargs="*", default=["."],
                    help="folder(s) to share (default: .)")
    ap.add_argument("--port", type=int, default=8420, help="port to listen on (0 = any free port)")
    ap.add_argument("--bind", default="127.0.0.1",
                    help="address to listen on (default: 127.0.0.1, tunnel-only)")
    ap.add_argument("--password", default=os.environ.get("FT_PASSWORD"),
                    help="access password (default: $FT_PASSWORD or auto-generated)")
    args = ap.parse_args()

    names = set()
    for directory in args.directories:
        real = os.path.realpath(os.path.expanduser(directory))
        if not os.path.isdir(real):
            sys.exit(f"error: {real} is not a directory")
        name = os.path.basename(real).lstrip(".") or "folder"
        base, i = name, 2
        while name in names:
            name, i = f"{base} ({i})", i + 1
        names.add(name)
        ROOTS.append((name, real))
    TITLE = ROOTS[0][0] if len(ROOTS) == 1 else "Shared folders"

    password = args.password or "".join(secrets.choice(PW_ALPHABET) for _ in range(10))
    PASSWORD = password.encode("utf-8")

    try:
        server = ThreadingHTTPServer((args.bind, args.port), Handler)
    except OSError as e:
        sys.exit(f"error: cannot listen on {args.bind}:{args.port} ({e.strerror})")

    for _, real in ROOTS:
        print(f"[ftransfer] sharing   {real}", flush=True)
    print(f"[ftransfer] listening http://{args.bind}:{server.server_address[1]}  "
          f"password: {password}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
