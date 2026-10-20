# Third-party software included in MacDM

MacDM ships with two separate command-line programs. MacDM runs them as separate
processes; it does not link to them.

## yt-dlp
- Purpose: finds and downloads video and audio from web pages.
- License: The Unlicense (public domain).
- Source and license: https://github.com/yt-dlp/yt-dlp
- MacDM can download newer official releases of yt-dlp from github.com (see Settings → General).

## FFmpeg
- Purpose: joins separate video and audio streams into one file.
- Version shipped: see `scripts/tools.lock`. It is a static Apple Silicon build from https://ffmpeg.martin-riedl.de
- License: GNU General Public License, version 3 (this build includes the GPL-licensed x264 and x265 encoders).
- FFmpeg is a trademark of Fabrice Bellard. Copyright (c) the FFmpeg developers.
- Source code for the shipped version: https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
  (build recipe and the x264/x265 sources: https://ffmpeg.martin-riedl.de)
- The full license text: https://www.gnu.org/licenses/gpl-3.0.html

If you would like the corresponding source code for the FFmpeg build included in a MacDM release,
open an issue at https://github.com/AsifAbu/MacDM/issues and it will be provided.
