#!/bin/bash
# Downloads the pinned yt-dlp and ffmpeg into vendor/ and verifies their checksums.
# Safe to run repeatedly: files that already match are not downloaded again.
# Usage: scripts/fetch-tools.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/tools.lock
mkdir -p vendor

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

fetch() {  # fetch <url> <dest> <sha256> <label>
  local url="$1" dest="$2" want="$3" label="$4"
  if [[ -f "$dest" && "$(sha "$dest")" == "$want" ]]; then echo "✔ $label already present"; return; fi
  echo "↓ Downloading $label"
  curl -fL --retry 3 -sS -o "$dest.part" "$url"
  local got; got="$(sha "$dest.part")"
  if [[ "$got" != "$want" ]]; then
    rm -f "$dest.part"
    echo "✖ $label checksum mismatch (expected $want, got $got). Not using it." >&2
    exit 1
  fi
  mv "$dest.part" "$dest"
  echo "✔ $label verified"
}

# yt-dlp: the zip holds "yt-dlp_macos" and an "_internal" folder. Unpack once into vendor/yt-dlp-dist.
if [[ ! -x vendor/yt-dlp-dist/yt-dlp_macos || ! -f vendor/yt-dlp-dist/.version-$YTDLP_ZIP_SHA256 ]]; then
  fetch "$YTDLP_ZIP_URL" vendor/yt-dlp.zip "$YTDLP_ZIP_SHA256" "yt-dlp $YTDLP_VERSION (zip)"
  rm -rf vendor/yt-dlp-dist
  ditto -x -k vendor/yt-dlp.zip vendor/yt-dlp-dist
  rm -f vendor/yt-dlp.zip
  [[ -x vendor/yt-dlp-dist/yt-dlp_macos && -d vendor/yt-dlp-dist/_internal ]] || { echo "✖ unexpected yt-dlp zip contents" >&2; exit 1; }
  touch "vendor/yt-dlp-dist/.version-$YTDLP_ZIP_SHA256"
fi
echo "✔ yt-dlp $YTDLP_VERSION ready"

if [[ ! -f vendor/ffmpeg || "$(sha vendor/ffmpeg)" != "$FFMPEG_SHA256" ]]; then
  fetch "$FFMPEG_ZIP_URL" vendor/ffmpeg.zip "$FFMPEG_ZIP_SHA256" "ffmpeg $FFMPEG_VERSION (zip)"
  unzip -oq vendor/ffmpeg.zip ffmpeg -d vendor
  rm -f vendor/ffmpeg.zip
  if [[ "$(sha vendor/ffmpeg)" != "$FFMPEG_SHA256" ]]; then
    echo "✖ ffmpeg binary does not match the pinned checksum." >&2; rm -f vendor/ffmpeg; exit 1
  fi
fi
chmod +x vendor/ffmpeg
echo "✔ ffmpeg $FFMPEG_VERSION verified"
