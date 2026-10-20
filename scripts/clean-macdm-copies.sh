#!/bin/bash
# Removes stale copies of MacDM from macOS's records, so Safari lists only ONE MacDM extension:
# the one in /Applications. Safe to run any time; it never deletes your installed app or your data.
#
# Why it is needed: macOS remembers every copy of the app it has ever seen, including ones opened
# from a mounted disk image or built by Xcode, and Safari shows an extension for each of them.
#
# Usage: scripts/clean-macdm-copies.sh [--eject]
#   --eject   also eject any MacDM disk images that are still mounted
set -uo pipefail
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
KEEP="/Applications/MacDM.app"

if [[ "${1:-}" == "--eject" ]]; then
  for v in /Volumes/MacDM*; do
    [[ -d "$v" ]] && hdiutil detach "$v" -quiet 2>/dev/null && echo "ejected $v"
  done
fi

count=0
while IFS= read -r app; do
  [[ -z "$app" || "$app" == "$KEEP" ]] && continue
  pluginkit -r "$app/Contents/PlugIns/SafariExtension.appex" 2>/dev/null
  "$LSR" -u "$app" 2>/dev/null
  count=$((count+1))
done < <("$LSR" -dump 2>/dev/null | grep -E "^[[:space:]]*path:.*/MacDM[^/]*\.app( \(0x[0-9a-f]+\))?$" \
          | sed -E 's/^[[:space:]]*path:[[:space:]]*//; s/ \(0x[0-9a-f]+\)$//' | sort -u)

echo "removed $count stale MacDM record(s)."
remaining=$("$LSR" -dump 2>/dev/null | grep -E "^[[:space:]]*path:.*/MacDM[^/]*\.app" | sed -E 's/^[[:space:]]*path:[[:space:]]*//; s/ \(0x[0-9a-f]+\)$//' | sort -u)
echo "macOS now knows these copies:"; echo "${remaining:-  (none)}" | sed 's/^/  /'
