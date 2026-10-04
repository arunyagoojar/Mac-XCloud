#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
xcrun swiftc "$ROOT/Mac XCloud/ControllerModels.swift" "$ROOT/Mac XCloud/MotionInputEngine.swift" "$ROOT/Tests/ControllerContracts.swift" -o "$SCRATCH/controller-contracts"
"$SCRATCH/controller-contracts"
