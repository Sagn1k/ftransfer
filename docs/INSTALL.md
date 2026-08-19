# Installing FTransfer (for coworkers)

Send files from your Mac to your phone when AirDrop and file sharing are
blocked, and your phone can't join the Mac's network.

**You do not need admin rights.** No Homebrew, no Python, no Xcode, no Apple
ID. Nothing gets installed system-wide — the app lands in your own
`~/Applications` folder.

## Install (copy-paste into Terminal)

Open **Terminal** (⌘-Space → "Terminal") and paste this one line:

```sh
curl -fsSL https://raw.githubusercontent.com/Sagn1k/ftransfer/dist/FTransfer-macos.zip -o /tmp/ftransfer.zip && rm -rf ~/Applications/FTransfer.app && mkdir -p ~/Applications && ditto -xk /tmp/ftransfer.zip ~/Applications && rm /tmp/ftransfer.zip && open ~/Applications/FTransfer.app
```

That's it — FTransfer opens and asks which folder(s) you want to share.

> **Why Terminal instead of clicking a download link?** macOS tags anything
> downloaded by a browser, Slack, or Mail with a "quarantine" flag, and then
> refuses to open it because the app isn't signed by a paid Apple developer
> account ("*FTransfer cannot be opened because it is from an unidentified
> developer*"). Files fetched with `curl` are not tagged, so the app just
> opens. Same app, same bytes — only the delivery method differs.

## Using it

1. FTransfer asks which folder(s) to share. **⌘-click to pick several.**
   (Tip: sharing a folder in your home directory, like `~/ftransfer-share`,
   avoids the extra macOS "allow access to Downloads/Desktop/Documents"
   prompt described below.)
2. Wait a few seconds for "Starting secure tunnel".
3. A window shows a **QR code, a link, and a password**.
4. **Scan the QR with your phone camera**, open the link, and sign in —
   any username, plus the password shown.
5. Browse and download your files. Tap **Select** to grab several at once as
   a `.zip`, or **Download all**.
6. Click **Stop Sharing** (or the 📦 icon in the menu bar) when you're done.

After the first launch, FTransfer lives in the **menu bar** as a 📦 icon
(top right of the screen). Click it to show the QR again, copy the link, or
stop sharing.

## The one prompt you will see

The first time you share `Desktop`, `Documents`, or `Downloads`, macOS asks:

> *"FTransfer" would like to access files in your Downloads folder.*

Click **OK**. That's macOS's normal privacy prompt for any app reading those
folders — it is not a security warning about the app, and it appears once per
folder. Sharing a folder elsewhere in your home directory avoids it entirely.

## Good to know

- **Each session gets a brand-new link and password.** Both stop working the
  moment you click Stop Sharing or quit the app.
- Anyone with the link **and** the password can read the shared folder while
  it's running, so only share what you mean to and stop when finished.
- Your phone can be on cellular data — it doesn't need to be on the same
  network as the Mac. It just needs internet.
- The connection is read-only: nothing on your Mac can be changed from the
  phone.
- **Keep the Mac awake** during transfers; if it sleeps, the download stops.
- Traffic passes through Cloudflare's network (that's what makes it reachable
  without opening any ports). Don't use it for anything your company forbids
  sending through third parties.

## Requirements

- macOS 12 (Monterey) or newer
- Apple Silicon Mac (M1 or newer). On an Intel Mac the app opens but needs
  `cloudflared` installed separately — ask Sagnik for an Intel build.

## Uninstall

```sh
rm -rf ~/Applications/FTransfer.app
```

Nothing else is left behind (settings live in
`~/Library/Preferences/com.sagnik.ftransfer.plist`, safe to delete too).

## Trouble?

| What you see | Fix |
|---|---|
| "cannot be opened because it is from an unidentified developer" | You downloaded it with a browser instead of the Terminal command. Delete it and use the `curl` one-liner above. |
| Stuck on "Starting secure tunnel" | Check your internet connection; if you're on a locked-down network, tunnels may be blocked entirely — try a hotspot. |
| Phone shows a Cloudflare error page | Sharing was stopped on the Mac, or the Mac slept. Start sharing again to get a fresh link. |
| Phone asks for a username | Type anything (e.g. `me`); only the password matters. |
| Can't find the app after installing | It's in `~/Applications` (your own Applications folder, not the system one). Or look for 📦 in the menu bar. |
