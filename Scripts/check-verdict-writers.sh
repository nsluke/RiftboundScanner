#!/bin/sh
# Fails if anything outside ScanRecord.swift assigns a scan's verdict, verdict
# time or decision log. Those are `private(set)` and only the store's
# `decide` appends to them (ADR-002, decision 6), so the compiler already
# refuses such writes; this keeps the rule visible in CI and catches a
# future loosening of the access level. Decision.swift is exempt only for
# `Decision.init` storing its own `let verdict`.
cd "$(dirname "$0")/.." || exit 1
pattern='\.(verdict|verdictAt|decisions)[[:space:]]*(=[^=]|\+=|\.append\(|\.remove|\.insert\()'
if grep -rnE "$pattern" App/Sources App/Tests --include='*.swift' | grep -vE '^App/Sources/Scans/(ScanRecord|Decision)\.swift:'; then
  echo "a verdict is written outside App/Sources/Scans/ScanRecord.swift; go through ScanStoring.decide" >&2
  exit 1
fi
if ! grep -qE 'private\(set\) var (decisions|verdict|verdictAt)' App/Sources/Scans/ScanRecord.swift; then
  echo "ScanRecord's decisions, verdict and verdictAt must stay private(set)" >&2
  exit 1
fi
echo "Verdicts are written only through ScanStoring.decide."
