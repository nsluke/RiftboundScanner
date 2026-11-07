#!/bin/zsh
# Builds Scripts/blescan.swift into a tiny .app bundle and launches it through `open`
# so macOS treats it as its own process for the Bluetooth permission prompt
# (a bare binary inherits the parent app's missing usage description and is killed by TCC).
#
#   Scripts/blescan.sh scan [seconds]
#   Scripts/blescan.sh dump <name|uuid> [listen-seconds]
#   Scripts/blescan.sh write <name|uuid> <char-uuid> <hex> [listen-seconds]
set -euo pipefail
root="${0:A:h:h}"
app="$root/.build/blescan.app"
bin="$app/Contents/MacOS/blescan"
src="$root/Scripts/blescan.swift"
plist="$root/Scripts/blescan-Info.plist"
if [[ ! -x "$bin" || "$src" -nt "$bin" || "$plist" -nt "$bin" ]]; then
  mkdir -p "$app/Contents/MacOS"
  cp "$plist" "$app/Contents/Info.plist"
  swiftc -swift-version 5 -O "$src" -o "$bin"
  codesign --force --sign - --identifier com.nsluke.blescan "$app"
fi
if ! codesign --verify "$app" 2>/dev/null; then
  codesign --force --sign - --identifier com.nsluke.blescan "$app"
fi
log="$(mktemp -t blescan)"
open -W -n --stdout "$log" --stderr "$log" -a "$app" --args "$@"
cat "$log"
rm -f "$log"
