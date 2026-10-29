#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.build/swift-module-cache"
FLAGS=(-swift-version 6 -parse-as-library -module-cache-path "$ROOT/.build/swift-module-cache")
xcrun swiftc "${FLAGS[@]}" "$ROOT/native/Sources/QuotaModels.swift" "$ROOT/native/Sources/ResetCreditModels.swift" "$ROOT/native/Sources/TokenActivity.swift" "$ROOT/native/Tests/CoreTests.swift" -o "$ROOT/.build/QuotaCoreTests"
xcrun swiftc "${FLAGS[@]}" "$ROOT/native/Sources/TokenActivity.swift" "$ROOT/native/Sources/ActivityHeatmap.swift" "$ROOT/native/Tests/HeatmapTests.swift" -o "$ROOT/.build/HeatmapTests"
"$ROOT/.build/HeatmapTests"
"$ROOT/.build/QuotaCoreTests"
xcrun swiftc "${FLAGS[@]}" -D STABILITY_TEST "$ROOT"/native/Sources/*.swift "$ROOT/native/Tests/MultiAccountTests.swift" -o "$ROOT/.build/MultiAccountTests"
"$ROOT/.build/MultiAccountTests"
xcrun swiftc "${FLAGS[@]}" -D STABILITY_TEST "$ROOT"/native/Sources/*.swift "$ROOT/native/Tests/MenuColorTests.swift" -o "$ROOT/.build/MenuColorTests"
"$ROOT/.build/MenuColorTests"
xcrun swiftc "${FLAGS[@]}" -D STABILITY_TEST "$ROOT"/native/Sources/*.swift "$ROOT/native/Tests/ResetCreditTests.swift" -o "$ROOT/.build/ResetCreditTests"
"$ROOT/.build/ResetCreditTests"
xcrun swiftc "${FLAGS[@]}" -D STABILITY_TEST "$ROOT"/native/Sources/*.swift "$ROOT/native/Tests/RecoveryTests.swift" -o "$ROOT/.build/RecoveryTests"
if [[ "${1:-}" == "--transport" ]]; then
  "$ROOT/.build/RecoveryTests" --transport
else
  "$ROOT/.build/RecoveryTests"
fi
xcrun swiftc "${FLAGS[@]}" -D STABILITY_TEST "$ROOT"/native/Sources/*.swift "$ROOT/native/Tests/StabilityTests.swift" -o "$ROOT/.build/StabilityTests"
if [[ "${1:-}" == "--ui" ]]; then
  "$ROOT/.build/StabilityTests" --ui
else
  "$ROOT/.build/StabilityTests"
fi
xcrun swiftc "${FLAGS[@]}" "$ROOT/native/Sources/QuotaModels.swift" "$ROOT/native/Sources/ResetCreditModels.swift" "$ROOT/native/Sources/TokenActivity.swift" "$ROOT/native/Sources/CodexClient.swift" "$ROOT/native/Tools/QuotaProbe.swift" -o "$ROOT/.build/QuotaProbe"
xcrun swiftc "${FLAGS[@]}" "$ROOT/native/Sources/ClientLogMonitor.swift" "$ROOT/native/Tools/MonitorProbe.swift" -o "$ROOT/.build/MonitorProbe"
if [[ "${1:-}" == "--watch" ]]; then
  "$ROOT/.build/MonitorProbe" "$ROOT/.build"
else
  printf 'Monitor test compiled; use --watch in a normal macOS terminal to exercise FSEvents.\n'
fi
