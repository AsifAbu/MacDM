#!/bin/bash
# Scans a built MacDM.app (or a .dmg / folder) for personal data before it is published.
# Fails (exit 1) if it finds your username, home folder, full name, git e-mail, download history,
# partial downloads or developer-machine leftovers.
# Usage: scripts/check-privacy.sh path/to/MacDM.app|MacDM.dmg
set -uo pipefail

target="${1:?usage: check-privacy.sh <MacDM.app | MacDM.dmg | folder>}"
mountpoint=""
cleanup() { [[ -n "$mountpoint" ]] && hdiutil detach "$mountpoint" -quiet >/dev/null 2>&1; }
trap cleanup EXIT

if [[ "$target" == *.dmg ]]; then
  mountpoint="$(mktemp -d /tmp/macdm-privacy.XXXXXX)"
  hdiutil attach "$target" -mountpoint "$mountpoint" -nobrowse -readonly -quiet || { echo "cannot open $target"; exit 2; }
  target="$mountpoint"
fi
[[ -e "$target" ]] || { echo "not found: $target"; exit 2; }

problems=0
report() { echo "  ✖ $1"; problems=$((problems+1)); }

echo "Scanning $1 ..."

# 1. Files that must never ship.
while IFS= read -r f; do report "unwanted file: ${f#$target/}"; done < <(
  find "$target" \( -name "tasks.json" -o -name "*.idmpart" -o -name "*.idmmeta" -o -name ".DS_Store" \
    -o -name "xcuserdata" -o -name "*.xcresult" -o -name ".git" -o -name "node_modules" -o -name ".env" \
    -o -name "embedded.provisionprofile" -o -name "*.dSYM" \) 2>/dev/null)

# 2. Personal strings inside any file, including the compiled binaries.
# Look for this person's own details, not generic words: third-party licence texts legitimately
# contain other people's e-mail addresses.
terms=("$USER" "$HOME" "$(id -F 2>/dev/null || true)" "$(git config user.email 2>/dev/null || true)")
extra="${PRIVACY_EXTRA_TERMS:-}"   # space-separated, e.g. a name or e-mail
for t in $extra; do terms+=("$t"); done
for term in "${terms[@]}"; do
  [[ -z "$term" || "$term" == "/" ]] && continue
  hits="$(grep -rlaF -- "$term" "$target" 2>/dev/null | head -5)"
  if [[ -n "$hits" ]]; then
    report "found \"$term\" in:"
    while IFS= read -r h; do echo "      ${h#$target/}"; done <<< "$hits"
  fi
done

if [[ $problems -eq 0 ]]; then
  echo "  ✔ No personal data found."
  exit 0
fi
echo "  $problems problem(s). Do not publish this build."
exit 1
