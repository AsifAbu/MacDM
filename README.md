# MacDM

A fast download manager for Mac. It splits big downloads into parts to finish sooner, resumes after a pause or a
restart, and downloads videos from web pages with a choice of quality. It lives in your menu bar and Dock, and it
can take over downloads from your browser.

## Download

<p align="center">
  <a href="https://github.com/AsifAbu/MacDM/releases/latest/download/MacDM.dmg">
    <img alt="Download MacDM for Mac" src="https://img.shields.io/badge/%E2%AC%87%20Download-MacDM.dmg-0A84FF?style=for-the-badge&logo=apple&logoColor=white">
  </a>
</p>

Clicking the button downloads **MacDM.dmg** straight away (about 72 MB). If the button doesn't show, use this link:
[**MacDM.dmg**](https://github.com/AsifAbu/MacDM/releases/latest/download/MacDM.dmg), or see all versions on the
[Releases page](https://github.com/AsifAbu/MacDM/releases).

Requires a Mac with **Apple silicon** (M1 or newer) running **macOS 14 or later**. It includes everything it needs,
so there is nothing else to install.

## Install

1. Open **MacDM.dmg**.
2. Drag **MacDM** onto the **Applications** folder in the window.
3. **Eject the disk image** (the eject button next to it in the Finder sidebar).
4. Open **MacDM** from Applications.

**The first time, macOS may say it can't verify the app.** MacDM is not yet signed with a paid Apple Developer ID.
This is a one-time step:

1. Open **System Settings → Privacy & Security**.
2. Scroll down and click **Open Anyway** next to MacDM, then confirm.

## Using MacDM

- MacDM starts quietly. Click its icon in the Dock or in the menu bar, then **Open MacDM**.
- **Add URL** downloads a link. **Site Grabber** lists the files on a web page. Copy a download link and MacDM
  offers to download it.
- **Speed:** each download uses 8 connections by default and splits the file into more pieces than that, so a slow
  connection doesn't hold the rest back. Change it in **Settings → Downloads** (1 to 32; above 8 rarely helps).
- Downloads are saved in a **MacDM** folder inside your Downloads folder, sorted into Video, Music, Documents and
  so on. Change this in **MacDM → Settings (Cmd+,) → General → Download location → Browse…**.
- While a file downloads, your download folder stays clean: the unfinished data is kept in a hidden folder of
  MacDM's own, and the finished file is moved into your download folder when it completes. Nothing else is left behind.
- A file never replaces one that is already there: if `Movie.mp4` exists, the new one is saved as `Movie (1).mp4`,
  then `Movie (2).mp4`.
- When the extension finds a video whose link has no real file name (just a long code), MacDM names the file after
  the page's title, with the right ending (`.mp4`, `.mkv`, `.mp3`…).
- The **✕** on a row cancels a running download and permanently deletes that download's unfinished data (it does not
  go to the Trash). Finished files are never touched. On a finished row, **✕** only removes the entry from the list;
  the file stays.
- Closing the window keeps MacDM running so it can catch downloads from your browser. **Cmd+Q** quits it.

## Site Grabber

Lists every file on a web page (or on the pages it links to, 1 or 2 levels deep, same site only) so you can pick
what to download. Filter by type (video, audio, images, documents, archives…), by name and by minimum size, then
**Select All** and **Download Selected**.

For pages that need a login, open the page in Chrome and use the **Grab all files on this page…** button on the
MacDM bar, or right-click the page and choose **Grab all files on this page with MacDM**. MacDM gets the page as you
see it, and sends your browser's cookies only to that same site.

## Videos

In Chrome with the MacDM extension, MacDM watches for video the way a download manager like IDM does: when a page
plays a video, **even inside an embedded player**, a **Download this video** bar appears on it. Click it, choose a
quality (or pick a detected file or stream), and MacDM does the rest. MacDM sends your browser's own cookies and
referrer with the download, so sites that check them accept it. The bar has a small **✕** to hide it and can be dragged
anywhere. Without the extension, paste the page address into **Add URL**.

Videos protected by DRM (Netflix, Disney+ and similar) cannot be downloaded by any download manager, and some sites
use links that only work once or only for your own connection.

MacDM includes the video tools it needs ([yt-dlp](https://github.com/yt-dlp/yt-dlp) and
[FFmpeg](https://ffmpeg.org)) and keeps yt-dlp up to date, because video sites change often. You can turn that off
in **Settings → Browser**.

## Browser extensions

### Chrome

1. In MacDM, open **Settings → Browser** and click **Copy Extension Folder**. MacDM copies the folder's path.
2. Click **Open Chrome…** (or go to `chrome://extensions` yourself) and turn on **Developer mode** (top right).
3. Click **Load unpacked**, press **⌘ + Shift + G**, paste the copied path, press **Return**, then click **Select**.
   (The folder is `~/Library/Application Support/MacDM/ChromeExtension`.)

The extension asks for permission to see network requests (to find videos in any player) and cookies (so downloads
work on sites you are signed in to). It only talks to MacDM on your own Mac.

After you update MacDM, press the reload arrow on the extension in Chrome once and accept the new permissions. Keep MacDM running while you browse.

### Safari

**Not available yet.** Safari only accepts extensions signed with an Apple certificate, and this release is not
signed with one. It will work in a signed release. Until then, use Chrome or **Add URL**. Details are in
[docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md).

## Privacy

- No account, no tracking, no analytics. Your download history and settings stay on your Mac.
- The browser extensions talk to MacDM only on your own Mac (`127.0.0.1`), never over your network. Web pages and
  other extensions cannot use it.
- MacDM contacts github.com only to check for a newer yt-dlp (at most once a day; you can turn it off).
- When you click **Download this video** in Chrome, the extension sends that page's sign-in (its cookies) to MacDM, so
  sites that check it, such as YouTube's "confirm you're not a bot", accept the request. MacDM keeps it in a private
  temporary file for that one download and deletes it when the download finishes or is cancelled. It is never saved
  in your history or settings, and MacDM never reads your browser's files.

## Uninstall

Open **MacDM → Settings → General → Uninstall MacDM…**. It moves MacDM to the Trash and, if you tick the box,
removes its history and settings too. Your downloaded files are never deleted. Remove the Chrome extension yourself
at `chrome://extensions`.

## Troubleshooting

| Problem | What to do |
|---|---|
| "MacDM can't be opened" the first time | System Settings → Privacy & Security → **Open Anyway** |
| MacDM isn't in the Dock after installing | Run `killall Dock` in Terminal |
| Chrome says `ERR_FILE_NOT_FOUND` for the extension | Remove it, then load the folder from Settings → Browser → Copy Extension Folder |
| A video site says "confirm you're not a bot" | Make sure you are signed in to the site in Chrome, pass any check it shows, reload the page and try again. If it keeps happening, wait a few minutes |
| MacDM's icon stays in the Dock after I quit it | macOS shows recent apps there. Turn off **System Settings → Desktop & Dock → Show suggested and recent apps in Dock** |
| **Uninstall MacDM…** is greyed out | You are running a copy from a disk image or Xcode. Quit it and open MacDM from the **Applications** folder |
| The extension shows "Extension context invalidated" | You reloaded the extension while a page was open. Reload that page (the old script stops by itself) |
| Several MacDM entries or old copies show up | Eject any leftover MacDM disk images, then run `scripts/clean-macdm-copies.sh --eject` |

More in [docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md).

## For developers

Build instructions, the test suite, project layout and the release process are in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Third-party software

MacDM includes yt-dlp (public domain) and FFmpeg (GPL v3), run as separate programs. See
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for licences and where to get the source.

## Licence

No licence has been chosen for MacDM's own code yet, so all rights are reserved by the author for now.
