#!/bin/sh
# Fails if the recogniser module imports a UI framework. It must stay droppable
# into an iOS app, so only Foundation, CoreGraphics, CoreImage, ImageIO,
# Accelerate, CryptoKit, UniformTypeIdentifiers and Vision are allowed.
cd "$(dirname "$0")/.." || exit 1
if grep -rnE '^[[:space:]]*import[[:space:]]+(AppKit|UIKit|SwiftUI|Cocoa|Cocoa\.)' Sources/RiftboundRecognizer; then
  echo "RiftboundRecognizer imports a UI framework" >&2
  exit 1
fi
echo "RiftboundRecognizer imports no UI framework."
