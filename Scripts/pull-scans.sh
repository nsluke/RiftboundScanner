#!/bin/sh
# Copies every scan batch off the phone with devicectl.
#   Scripts/pull-scans.sh [destination]   (default: ./scans)
# DEVICE can be a UDID or the phone's name; the default is Luke's iPhone 16 Pro.
set -eu
DEVICE="${DEVICE:-00008140-000234390ABB801C}"
DEST="${1:-scans}"
BUNDLE_ID="com.nsluke.RiftboundScanner"
mkdir -p "$DEST"
xcrun devicectl device copy from \
  --device "$DEVICE" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" \
  --source Documents/Scans \
  --destination "$DEST"
echo "Pulled scans into $DEST"
