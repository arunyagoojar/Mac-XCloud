#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
xcrun swiftc -parse-as-library "$ROOT/Mac XCloud/ControllerModels.swift" "$ROOT/Mac XCloud/InputPresetStore.swift" "$ROOT/Tests/PresetStoreContracts.swift" -o "$SCRATCH/preset-contracts"
"$SCRATCH/preset-contracts"
