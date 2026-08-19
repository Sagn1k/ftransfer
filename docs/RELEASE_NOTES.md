# FTransfer 1.0.0

Share a folder from your Mac to your phone through a Cloudflare quick tunnel —
no AirDrop, no same-network requirement, no accounts, and **no admin rights**.

## Install

Paste into Terminal (do **not** download with a browser — see below):

```sh
curl -fsSL https://raw.githubusercontent.com/Sagn1k/ftransfer/dist/FTransfer-macos.zip -o /tmp/ftransfer.zip && rm -rf ~/Applications/FTransfer.app && mkdir -p ~/Applications && ditto -xk /tmp/ftransfer.zip ~/Applications && rm /tmp/ftransfer.zip && open ~/Applications/FTransfer.app
```

Full walkthrough: [docs/INSTALL.md](INSTALL.md).

## What's in the app

- Pick one or more folders, get a **QR code, link, and password**
- Mobile web UI: previews, one-tap downloads, multi-select and bulk `.zip`
- Read-only, password-protected (fresh random password per session)
- Menu bar control: show QR, copy link/password, stop sharing

## Self-contained on purpose

The app needs **nothing** installed on the machine that runs it — no
Homebrew, no Python, no Xcode Command Line Tools, no Apple ID, no admin
password:

- The HTTP server is written in Swift and runs in-process (the CLI's
  `server.py` is not used by the app), so `/usr/bin/python3` — which is an
  Xcode Command Line Tools stub that prompts for an admin install — is never
  touched.
- `cloudflared` is bundled inside the app bundle.
- Installs into `~/Applications`, which needs no elevation.

## Why the Terminal command instead of a download link

macOS attaches a *quarantine* flag to anything a browser, Slack, or Mail
downloads, and then Gatekeeper refuses to open it because the app isn't signed
with a paid Apple Developer certificate. Files fetched with `curl` carry no
such flag, so the identical app opens with no warning at all. (Verified both
ways: unquarantined launches cleanly; quarantined is rejected by Gatekeeper.)

The one prompt you will still see is macOS's normal privacy request when the
app first reads `Desktop`, `Documents`, or `Downloads`. Sharing a folder
elsewhere in your home directory avoids even that.

## Requirements

macOS 12 or newer, Apple Silicon or Intel — both the app and the bundled
tunnel binary are universal.

## Verifying this build

```sh
shasum -a 256 FTransfer-macos.zip
codesign -dv --verbose=2 FTransfer.app   # ad-hoc signature, identifier com.sagnik.ftransfer
```

Or build it yourself from source: `scripts/release.sh`.
