#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
xcrun swiftc -parse-as-library "$ROOT/Mac XCloud/BetterXCloud.swift" "$ROOT/Mac XCloud/KeyboardMouse.swift" "$ROOT/Tests/KeyboardLayerContracts.swift" -o "$SCRATCH/keyboard-layer-contracts"
"$SCRATCH/keyboard-layer-contracts"
