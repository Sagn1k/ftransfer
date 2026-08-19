# 📦 ftransfer

**Send files from your Mac to your phone when nothing else works.**

![CI](https://github.com/Sagn1k/ftransfer/actions/workflows/ci.yml/badge.svg)
![macOS](https://img.shields.io/badge/macOS-12%2B-black)
![Python](https://img.shields.io/badge/python-3.9%2B%20stdlib%20only-blue)
![License](https://img.shields.io/badge/license-MIT-green)

<img align="right" src="docs/screenshot.png" width="280" alt="ftransfer web UI on a phone">

AirDrop disabled? File sharing blocked by IT? Phone not allowed on the same
network? **ftransfer** shares a folder from your Mac through a
[Cloudflare quick tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/trycloudflare/),
so your phone can browse and download the files from anywhere with just a
browser — no app to install, no accounts, no same-network requirement.

- **One command** — `./start.sh` prints a public URL, a fresh password, and a
  QR code to scan with your phone camera
- **Menu bar app** — or open FTransfer.app: pick folders, scan the QR window
- **Multiple folders** — share several directories at once; the root page
  lists each one
- **Bulk download** — tap **Select** to pick several files (or folders) and
  grab them as one .zip, or **Download all** for the entire share
- **Password-protected** — HTTPS + Basic Auth with a new random password per run
- **Download-only** — nothing on the Mac can be modified from the phone
- **Zero dependencies, no admin rights** — the distributed app bundles
  everything (see [Give it to your team](#give-it-to-your-team)); the CLI is a
  single stdlib-only Python file plus `cloudflared`
- **Mobile-friendly UI** — file icons, sizes, previews, one-tap downloads,
  dark mode

<br clear="right">

## Quick start (CLI)

```sh
brew install cloudflared        # one-time
git clone https://github.com/Sagn1k/ftransfer && cd ftransfer

./start.sh                      # shares ./shared (created if missing)
```

You'll get:

```
 ─────────────────────────────────────────────────────
  ftransfer is live

  URL       https://random-words-here.trycloudflare.com
  Username  files   (anything works)
  Password  wmm28zt2mn
  Folder    /Users/you/ftransfer/shared
 ─────────────────────────────────────────────────────
  [QR code — scan it with your phone camera]
```

Open the URL on the phone, sign in with any username + that password, tap a
file to preview it or **↓** to download. Use **Select** to multi-pick files
and folders into one .zip, or **⬇ Download all (zip)** for everything.
`Ctrl+C` stops sharing.

```sh
./start.sh ~/Downloads               # share any folder
./start.sh ~/Downloads ~/Desktop     # share several folders at once
FT_PASSWORD=mypass ./start.sh        # fixed password
PORT=9000 ./start.sh                 # fixed port
caffeinate -i ./start.sh             # keep the Mac awake while sharing
```

Install `qrencode` (`brew install qrencode`) to get the terminal QR code.

## Menu bar app

<img align="right" src="docs/app-window.png" width="270" alt="FTransfer QR window">

A native macOS menu bar app wraps the same flow: pick folders, get a QR
window, copy the link/password, stop with one click.

```sh
make app                       # builds clients/mac/FTransfer.app (needs Xcode CLT)
open clients/mac/FTransfer.app
```

On launch the app immediately asks which folder(s) to share (⌘-click to
select several). Once the tunnel is up, a window pops up with the QR code,
the password, and a Stop button. Afterwards the app lives in the **menu bar**
as a 📦 icon (top-right) — click it to show the QR again, copy the link, or
stop sharing. Re-opening the app from Finder also brings the window back.

> On MacBooks with a notch, a crowded menu bar can hide new icons — if you
> don't see 📦, close some other menu bar apps or use the app's windows.

<br clear="right">

## Give it to your team

Coworkers install with one Terminal line — **no admin rights, no Homebrew, no
Python, no Xcode, no Apple ID**:

```sh
curl -fsSL https://raw.githubusercontent.com/Sagn1k/ftransfer/dist/FTransfer-macos.zip -o /tmp/ftransfer.zip && rm -rf ~/Applications/FTransfer.app && mkdir -p ~/Applications && ditto -xk /tmp/ftransfer.zip ~/Applications && rm /tmp/ftransfer.zip && open ~/Applications/FTransfer.app
```

Hand them [docs/INSTALL.md](docs/INSTALL.md) — it covers the whole flow in
plain language.

### Why this avoids the "unidentified developer" wall

macOS only blocks apps carrying a **quarantine** flag, which browsers, Slack,
and Mail attach to their downloads. `curl` doesn't set it, so the identical app
opens with no warning. Verified both ways: the curl-delivered copy launches
cleanly, and the same bundle with a quarantine flag is `rejected` by
Gatekeeper. Signing and notarizing (a paid Apple Developer account) is only
needed if you want *browser* downloads to open cleanly.

The app is deliberately **self-contained**, which is what removes the admin
requirement — `/usr/bin/python3`, `git`, `make`, and `swiftc` are all Xcode
Command Line Tools stubs that pop an admin-gated installer, so the app touches
none of them:

- the HTTP server is a Swift port compiled into the app (the CLI's `server.py`
  isn't used by it)
- `cloudflared` ships inside the app bundle
- it installs to `~/Applications`, which needs no elevation

The one prompt that remains on any path is macOS's normal privacy request the
first time the app reads `Desktop`, `Documents`, or `Downloads`. Sharing a
folder elsewhere in your home directory avoids even that.

### Cutting a new build

```sh
scripts/release.sh          # universal app + bundled tunnel → dist/FTransfer-macos.zip
```

It verifies architectures, the signature, and actually serves a file from the
packaged binary before declaring success. Publish by committing the zip to the
`dist` branch (served from `raw.githubusercontent.com`, which stays reachable
on networks that block GitHub's release-asset host).

If a `cloudflared` architecture can't be downloaded on your network, the script
warns and ships without it — grab the artifact from CI's **Universal release
build** job instead, which always has both.

## How it works

```mermaid
flowchart LR
    P["📱 phone browser<br/>(anywhere on the internet)"] -->|HTTPS| E["Cloudflare edge<br/>xxxx.trycloudflare.com"]
    E <-->|outbound-only tunnel| C["cloudflared<br/>on the Mac"]
    C -->|localhost| S["server.py<br/>127.0.0.1"]
    S --> F[("shared folder")]
```

`server.py` serves one folder over HTTP with Basic Auth, bound to
`127.0.0.1` only. `cloudflared` opens an **outbound** connection to
Cloudflare and gets a throwaway public hostname — no ports are opened on the
Mac, no firewall or router changes, which is why it works on locked-down
machines and networks.

### Security model

- The URL is a random unguessable subdomain **and** every request requires
  the password (checked with constant-time comparison).
- New URL + new password on every run; both die when you hit `Ctrl+C`.
- The server never binds to the network — only the tunnel can reach it.
- Read-only: `GET`/`HEAD` only. Dotfiles are hidden and never served.
  Path traversal and symlink escapes are blocked.
- Trade-off to be aware of: traffic transits Cloudflare, and anyone holding
  both the URL and password can read the shared folder while it runs. Share
  only what you need, stop it when done.

## Troubleshooting

| Symptom | Fix |
|---|---|
| URL prints but the page shows Cloudflare error 1033 / HTTP 530 | Your network drops UDP 7844 (QUIC). ftransfer already defaults to the TCP transport (`CF_PROTOCOL=http2`); if you overrode it, unset it. |
| `cloudflared not found` | `brew install cloudflared` |
| Downloads stall mid-transfer | The Mac went to sleep — use `caffeinate -i ./start.sh`. |
| Video won't play inline on iPhone | Use the ↓ button to download it instead (range requests are supported, but codecs vary). |
| Zip downloads show no total size / progress % | Expected — zips are streamed on the fly, so the size isn't known up front. The download still completes normally. |
| Need a URL that never changes | Quick tunnels are throwaway by design. Create a free Cloudflare account and a [named tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/), then point it at `http://127.0.0.1:8420`. |

## Development

```
server.py                     CLI server (stdlib only, one file)
start.sh                      CLI launcher: server + tunnel + QR
clients/mac/Sources/
  main.swift                  menu bar app: folder picker, QR window, tunnel
  FileServer.swift            Swift port of server.py (in-process, no Python)
  Zip.swift                   streaming zip writer (store-only, zip64)
clients/mac/build.sh          → FTransfer.app  (--universal for releases)
scripts/release.sh            → dist/FTransfer-macos.zip (self-contained)
tests/smoke.sh                black-box tests: auth, ranges, traversal, zips
tests/parity.sh               proves both servers behave identically
docs/INSTALL.md               the page to hand coworkers
```

```sh
make test            # smoke tests (Python server)
make parity          # diff the Python and Swift servers
make app             # build the menu bar app
make release         # build the distributable zip
make start           # share ./shared
```

Two server implementations could drift, so `tests/parity.sh` runs both over
the same fixture tree and requires **byte-identical HTML**, matching status
codes and range bytes, and zip archives with the same entries — a UI tweak in
one without the other fails CI.

## License

[MIT](LICENSE)
