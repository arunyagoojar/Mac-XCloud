#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
python3 - "$ROOT" "$SCRATCH" <<'PY'
from pathlib import Path
import sys
root, scratch = map(Path, sys.argv[1:])
source = (root / 'Mac XCloud/InputPresetStore.swift').read_text()
start = source.index('struct CustomAdaptiveTriggerPreset:')
end = source.index('private struct PresetEnvelope', start)
(scratch / 'PresetModel.swift').write_text('import Foundation\n' + source[start:end])
PY
xcrun swiftc "$ROOT/Mac XCloud/ControllerModels.swift" "$SCRATCH/PresetModel.swift" "$ROOT/Tests/ControllerContracts.swift" -o "$SCRATCH/controller-contracts"
"$SCRATCH/controller-contracts"
