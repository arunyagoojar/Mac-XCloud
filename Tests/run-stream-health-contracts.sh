#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
xcrun swiftc -parse-as-library "$ROOT/Mac XCloud/StreamHealthAnalysis.swift" "$ROOT/Mac XCloud/GameSetupKind.swift" \
  "$ROOT/Mac XCloud/ControllerModels.swift" "$ROOT/Mac XCloud/MotionInputEngine.swift" \
  "$ROOT/Tests/StreamHealthContracts.swift" -o "$SCRATCH/stream-health-contracts"
"$SCRATCH/stream-health-contracts"
