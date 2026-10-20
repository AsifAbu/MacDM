#!/bin/bash
# Runs the full MacDM regression suite: extension tests (Node) + app tests (Xcode).
# Usage: scripts/test.sh [--extensions-only | --app-only]
# Exits non-zero if anything fails, so it can gate a release or a git push.
# It builds in its own folder (build/) so it never clashes with Xcode's build cache.
set -uo pipefail
cd "$(dirname "$0")/.."

mode="${1:-all}"

# A running MacDM clashes with the copy the app tests start and makes them hang.
# (The extension tests don't care.)
if [[ "$mode" != "--extensions-only" ]] && pgrep -x MacDM >/dev/null; then
  echo "✖ MacDM is running. Quit it first (menu bar icon or Dock ▸ Quit), then run the tests again."; exit 2
fi
failed=0

if [[ "$mode" != "--app-only" ]]; then
  echo "==> Extension tests (Chrome + Safari)"
  if ! command -v node >/dev/null; then
    echo "node is required: brew install node"; exit 2
  fi
  (
    cd tests
    [[ -d node_modules ]] || npm install --silent
    npm test --silent
  ) || { echo "✖ Extension tests FAILED"; failed=1; }
fi

if [[ "$mode" != "--extensions-only" ]]; then
  echo "==> App tests (download engine, queue, local server, media options)"
  log="$(mktemp -t macdm-xcodebuild)"
  if xcodebuild test \
      -project MacDM.xcodeproj -scheme MacDM \
      -destination 'platform=macOS,arch=arm64' \
      -derivedDataPath build/DerivedData \
      -quiet > "$log" 2>&1; then
    echo "✔ App tests passed"
  else
    echo "✖ App tests FAILED. Last lines of the log:"
    grep -E "error:|✘|Expectation failed|recorded an issue|failed" "$log" | cut -c1-220 | head -30
    echo "(full log: $log)"
    failed=1
  fi
fi

# The test build is a second copy of the app; make macOS forget it so Safari lists only one MacDM.
scripts/clean-macdm-copies.sh >/dev/null 2>&1 || true

if [[ $failed -eq 0 ]]; then
  echo; echo "✔ All tests passed. Safe to release."
else
  echo; echo "✖ Tests failed. Do not release."
fi
exit $failed
