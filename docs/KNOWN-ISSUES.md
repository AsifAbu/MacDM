# MacDM: known issues and things we learned

Last updated: 2026-10-20. Tested on macOS 27.0.1 ("Golden Gate"), Apple Silicon.

## 1. Safari extension does not appear in Safari → Settings → Extensions

**Status:** open. Waiting for a real signing certificate. Chrome works in the meantime.

**What you see:** MacDM is installed and running, but MacDM is not in Safari's list of extensions, even with
"Allow unsigned extensions" turned on.

**Why:** Safari's log says
`Computing the code signing dictionary failed for extension … does not have a code signature`.
MacDM is signed only with an ad-hoc ("Sign to Run Locally") signature. This Safari rejects that.
It is not a packaging mistake: an extension built directly by Xcode fails in exactly the same way.
The extension is installed correctly (macOS lists it as a Safari web extension) and its signature passes
every check we can run.

**How to confirm in the future** (use `/usr/bin/log`, because plain `log` is a different command in zsh):

```
/usr/bin/log show --last 10m --style compact --predicate \
  'process == "Safari" AND category == "Extensions" AND eventMessage CONTAINS[c] "yourcompany"'
```

**Ways to fix it:**
- *Free, for your own Mac only:* in Xcode, set your free **Personal Team** on both the MacDM and
  SafariExtension targets so Xcode creates an "Apple Development" certificate, then build the DMG with
  `SIGN_IDENTITY="Apple Development: …" scripts/build-dmg.sh`. Not tried yet; you chose to wait.
- *For everyone:* a paid Apple Developer ID, then sign and notarize. See `scripts/build-dmg.sh`.

**Workaround today:** use the Chrome extension. Folder: `~/Library/Application Support/MacDM/ChromeExtension`
(Chrome → `chrome://extensions` → Developer mode → Load unpacked).

## 2. Dock icon

MacDM is a normal Mac app, so it has a Dock icon for as long as it runs. If the icon is missing after a reinstall,
macOS's Dock process just missed it: run `killall Dock` in Terminal and it appears. Do not go back to switching the
icon on and off while windows open and close; that was unreliable.

## 3. Several MacDM extensions listed in Safari

macOS remembers every copy of the app it has ever seen: mounted disk images, apps in the Trash, and build folders.
Safari shows an extension for each one.

- Eject the DMG as soon as you have dragged the app to Applications.
- Run `scripts/clean-macdm-copies.sh --eject` to make macOS forget every copy except the one in `/Applications`.

## 4. Reinstalling shows the old history and download folder

Deleting an app does not delete its data. MacDM keeps history and settings in `~/Library`. To test as a brand-new
user, use **Settings → General → Uninstall MacDM…** (tick "delete my history and settings") or run
`scripts/reset-macdm-data.sh` (moves everything to a backup on your Desktop; `--dry-run` shows what it would do).
Downloaded files are never touched.

## 5. Full Disk Access is asked for again after every reinstall

Because the app is not signed with a developer certificate, macOS treats each new build as a new app. Only needed if
you use "Use cookies from Safari" for sites such as YouTube.

## 6. Running the tests

`scripts/test.sh` runs everything in about 15 seconds. Quit MacDM first: a running copy makes the app tests hang, and
the script refuses to start while MacDM is open.

## 7. Only one Mac and one macOS version have been tested

Everything above was tested on one Apple Silicon Mac running macOS 27.0.1. MacDM targets all Apple Silicon Macs on
macOS 14 or newer, so try the DMG on another macOS version before a public release.
