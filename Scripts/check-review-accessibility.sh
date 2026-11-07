#!/bin/sh
# Every review-flow view added by ADR-002 work item A6 names its controls for
# VoiceOver. Fails when one of them has no accessibility label or hint, which
# is as far as a grep can take the "VoiceOver labels exist" clause; the rest
# is the manual check in the README.
set -eu
cd "$(dirname "$0")/.."
status=0
for file in \
  App/Sources/Scanner/StartRunSheet.swift \
  App/Sources/Scanner/RunCompleteStrip.swift \
  App/Sources/Review/PrintingPickerView.swift \
  App/Sources/Review/ReviewQueueView.swift \
  App/Sources/Review/FixMatchView.swift \
  App/Sources/Collection/AddCardSheet.swift
do
  labels=$(grep -c 'accessibilityLabel(' "$file" || true)
  hints=$(grep -c 'accessibilityHint(' "$file" || true)
  if [ "$labels" -eq 0 ] || [ "$hints" -eq 0 ]; then
    echo "$file: $labels accessibility labels, $hints hints; every A6 view needs both" >&2
    status=1
  fi
done
# The duplicate row's two choices and the printing chips must be reachable by name.
for needle in '"Keep both"' '"Drop"' 'accessibilityAddTraits(isSelected' 'Other printings'; do
  if ! grep -rq -- "$needle" App/Sources/Review; then
    echo "App/Sources/Review: missing $needle" >&2
    status=1
  fi
done
if [ "$status" -eq 0 ]; then
  echo "review accessibility: ok"
fi
exit "$status"
