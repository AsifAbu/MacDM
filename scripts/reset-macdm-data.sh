#!/bin/bash
# Makes MacDM start like a brand-new install on this Mac: empty history, default download folder,
# default settings. Use it to test the first-run experience.
#
# Nothing is deleted: everything is MOVED into a backup folder on your Desktop, so it can be restored.
# Your downloaded files are never touched. Saved passwords in your Keychain are left alone too,
# unless you add --keychain.
#
# Usage: scripts/reset-macdm-data.sh [--dry-run] [--keychain]
set -uo pipefail
BUNDLE="com.yourcompany.MacDM"
DRY=0; KEYCHAIN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --keychain) KEYCHAIN=1 ;;
    *) echo "unknown option: $arg"; exit 2 ;;
  esac
done

# Paths relative to ~/Library that hold MacDM's data.
ITEMS=(
  "Application Support/MacDM"                       # download history, Chrome extension copy, updated yt-dlp
  "Preferences/$BUNDLE.plist"                       # settings, including the download folder
  "Caches/MacDM"
  "Caches/$BUNDLE"
  "HTTPStorages/$BUNDLE"
  "Saved Application State/$BUNDLE.savedState"
)

BACKUP="$HOME/Desktop/MacDM-data-backup-$(date +%Y-%m-%d-%H%M%S)"
echo "MacDM data on this Mac:"
found=0
for rel in "${ITEMS[@]}"; do
  src="$HOME/Library/$rel"
  [[ -e "$src" ]] && { printf "  %-60s %s\n" "~/Library/$rel" "$(du -sh "$src" 2>/dev/null | cut -f1)"; found=1; }
done
[[ $found -eq 0 ]] && { echo "  (none, MacDM is already in a fresh state)"; exit 0; }

if [[ $DRY -eq 1 ]]; then
  echo; echo "Dry run: nothing was changed. Run without --dry-run to move this into:"; echo "  $BACKUP"
  exit 0
fi

pkill -x MacDM 2>/dev/null; sleep 1
mkdir -p "$BACKUP"
# Settings live in a cache owned by macOS (cfprefsd); export then delete them the supported way.
defaults export "$BUNDLE" "$BACKUP/preferences-export.plist" 2>/dev/null
defaults delete "$BUNDLE" 2>/dev/null
for rel in "${ITEMS[@]}"; do
  src="$HOME/Library/$rel"
  if [[ -e "$src" ]]; then
    mkdir -p "$BACKUP/$(dirname "$rel")"
    mv "$src" "$BACKUP/$rel"
  fi
done
killall cfprefsd 2>/dev/null   # make sure no old settings are served from memory

if [[ $KEYCHAIN -eq 1 ]]; then
  n=0; while security delete-generic-password -s "$BUNDLE" >/dev/null 2>&1; do n=$((n+1)); done
  echo "removed $n saved password(s) from the Keychain"
fi

echo; echo "✔ MacDM will start fresh the next time you open it."
echo "  Backup of the old data: $BACKUP"
echo "  To undo: quit MacDM and move the folders in that backup back into ~/Library."
