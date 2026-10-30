# Developing MacDM

## Requirements

- A Mac with Apple silicon, macOS 14 or later, and **Xcode**.
- `node` (for the browser-extension tests): `brew install node`.

## Build and run

1. Open `MacDM.xcodeproj` in Xcode.
2. Select the **MacDM** scheme and **My Mac**, then press **Cmd+R**.

The Xcode project is the source of truth. `project.yml` is an old XcodeGen file that is out of date; do not
regenerate the project from it.

Running from Xcode uses yt-dlp and ffmpeg from Homebrew if they are installed
(`brew install yt-dlp ffmpeg`); the release build bundles its own.

## Tests

```
scripts/test.sh                      # everything (about 15 seconds)
scripts/test.sh --extensions-only    # Chrome and Safari extension tests only (Node)
scripts/test.sh --app-only           # app tests only
```

**Quit MacDM before running the tests.** A running copy makes the app tests hang, so the script refuses to start
while MacDM is open. In Xcode, **Cmd+U** runs the app tests.

What is covered: the download engine against an in-process test server (segments, pause/resume, cancel), the queue
and persistence, the local server's security rules, the yt-dlp updater (with a fake GitHub), the Chrome extension's
logic, and the video bar in the extensions (with jsdom).

## Project layout

```
MacDM/                  the app
  Engine/               downloads: segments, queue, yt-dlp jobs
  Services/             local server, security rules, updater, uninstaller, Chrome extension copy
  Views/                SwiftUI screens
  Models/               download task model
MacDMTests/             app tests (Swift Testing)
ChromeExtension/        Manifest V3 extension; talks to the app over 127.0.0.1
SafariExtension/        Safari web extension
tests/                  extension tests (Node)
scripts/                build, test, cleanup and release scripts
assets/AppIcon.icns     app icon (regenerate with scripts/make-icon.swift)
docs/                   this guide and KNOWN-ISSUES.md
```

## Building the DMG

```
scripts/build-dmg.sh
```

This fetches yt-dlp and ffmpeg (pinned by version and SHA-256 in `scripts/tools.lock`), builds a Release app for
Apple silicon, trims the unused Intel code from yt-dlp's libraries, signs everything, checks the result for personal
data (`scripts/check-privacy.sh`), and writes `dist/MacDM.dmg`.

- Signing is ad-hoc by default. With an Apple Developer ID:
  `SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-dmg.sh`
  (notarization is not wired up yet).
- Run `scripts/test.sh` first.
- Never publish a Debug build: it contains your username and file paths.

## Releasing

1. `scripts/test.sh` passes.
2. `scripts/build-dmg.sh` finishes with "No personal data found".
3. Try the DMG on a Mac that has never had MacDM (or run `scripts/reset-macdm-data.sh --dry-run` to see what a
   fresh state means on yours).
4. Create a GitHub release (tag, for example `v1.0`) and attach `dist/MacDM.dmg`, **named exactly `MacDM.dmg`**, so
   the README's "latest release" link keeps working.

## Useful scripts

| Script | What it does |
|---|---|
| `scripts/test.sh` | Runs all tests |
| `scripts/build-dmg.sh` | Builds the release DMG |
| `scripts/fetch-tools.sh` | Downloads the pinned yt-dlp and ffmpeg into `vendor/` |
| `scripts/check-privacy.sh <app or dmg>` | Looks for your username, home folder, name or email inside a build |
| `scripts/clean-macdm-copies.sh [--eject]` | Makes macOS forget stray copies of MacDM (fixes duplicate Safari extensions) |
| `scripts/reset-macdm-data.sh [--dry-run]` | Moves MacDM's history and settings to a backup, for testing a first run |
| `scripts/make-icon.swift` | Regenerates `assets/AppIcon.icns` |

## How it works

- The browser extension sends requests to the app at `http://127.0.0.1:57643/api`. The app only accepts requests
  from its own Chrome extension (fixed ID, pinned by the `key` in `ChromeExtension/manifest.json`) and from Safari web
  extensions, only for http and https links, and cleans file names. See `Services/RequestSecurity.swift`.
- Both local ports (57642 and 57643) listen on `127.0.0.1` only.
- If the Chrome extension is ever published on the Chrome Web Store with a different ID, add that ID to
  `RequestSecurity.chromeExtensionIDs`. A test checks the manifest key and the app agree.
- yt-dlp ships as the multi-file build in `Contents/Resources/yt-dlp`, ffmpeg in `Contents/Helpers`. The single-file
  yt-dlp build took about 9 seconds to start on every run, which is why it is not used.
- Speed: `DownloadEngine` runs a pool of `connectionsPerDownload` workers (default 8, 1 to 32) over more pieces than
  connections (`pieceCount`). Measured against real servers, more than 8 gave no gain and slowed some servers down,
  hence the default. yt-dlp jobs use `-N` for parallel fragments.
- Browser downloads carry the browser's own Referer, Cookie and User-Agent (`DownloadTask.requestHeaders`, kept across
  relaunches). Only those headers are accepted from the extension (`RequestSecurity.safeHeaders`).
- The Chrome extension watches network traffic (`webRequest`) to find media in any frame and reads cookies (`cookies`)
  for grabbing; both permissions are checked by `tests/extension/manifest.test.js`.
- Site Grabber (`Services/SiteGrabber.swift`, `Views/SiteGrabberView.swift`): link extraction, same-site crawl to a
  depth of 2, size probing and filters. Chrome sends the rendered page's links with the `grab` action; cookies are
  only attached to links on the same site as the page.
- Unfinished files: each download has its own hidden folder, `~/Library/Application Support/MacDM/Incomplete/<download id>/`
  (`DownloadTask.workFolder`), holding the part file, the resume info and, for videos, yt-dlp's temporary files
  (`-P temp:`). The finished file is moved into the download folder, then the work folder is deleted.
  `DownloadTask.deleteUnfinishedFiles()` is the only deleter: it removes that one folder (never anything not named
  after the download's id) permanently, not to the Trash. Downloads from older versions have no `workFolder`; for those
  it removes just their own `name.idmpart` and `name.idmmeta`. On launch, work folders that belong to no resumable
  download are removed. Tests: `WorkFolderTests`.
- Sign-in for videos: the "Use cookies from" setting is gone (it needed Full Disk Access and Keychain prompts, and
  could not see the browser profile in use). For `formats` and `download_media` the Chrome background script adds the
  cookies the browser would send to that page (`pageCookies`; YouTube also gets Google's). The app validates them
  (`RequestSecurity.safeCookies`), writes a private (0600) Netscape `cookies.txt` (`CookieFile`) — a one-off temp file
  for the lookup, or `cookies.txt` inside the download's hidden folder for the download — and passes `--cookies`.
  They are never put in `tasks.json`, and the cached lookup result is scrubbed of cookie fields
  (`MediaInfoCache.scrubbed`). Tests: `SignInTests`, `tests/extension/signin.test.js`.
- Names: `FileNaming.moveWithoutReplacing` is the only way a finished file enters the download folder. It picks the
  first free name (`name`, `name (1)`, `name (2)`…) under a lock and never replaces a file; plain downloads and yt-dlp
  videos both use it (a video finishes inside its hidden folder, then is moved in). A detected file whose link has no
  file ending is named by the page script (`suggestedName` in `content.js`): the page title plus the ending from its
  content type. Tests: `FileNamingTests` and the "naming a detected file" tests in `content.test.js`.
- Quality list (`content.js`: `describeQuality`, `qualityName`, `qualityRow`): four fixed-width grid columns shared by the
  heading and every row (an `auto` column would shrink in the heading and misalign it). The app sends each option's
  `width`, `height` and, for audio, `detail` (`MediaExtractor.audioDetail`); these are display-only, the download uses
  the unchanged `selector`. Names use the shorter side (4K, 2K, Full HD, HD, SD, Low). Tests: `QualityDetailsTests`,
  `AudioDetailTests`, and the "Choose quality" tests in `content.test.js`.
