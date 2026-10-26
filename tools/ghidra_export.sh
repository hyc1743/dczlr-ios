#!/bin/bash
# Export decompiled functions from the existing local Ghidra project.
# Usage: ghidra_export.sh OUTDIR 0xADDR [0xADDR ...]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$1"; shift
case "$OUT" in
  [A-Za-z]:*|/*) : ;;
  *) OUT="$ROOT/$OUT" ;;
esac
GHIDRA="$ROOT/.tools/ghidra/ghidra_12.1.4_PUBLIC"
JAVA_BIN="C:/Users/hyc/Documents/projects/weixing3/.tools/jdk/jdk-21.0.12.1+1/bin/java.exe"
[ -f "$JAVA_BIN" ] || JAVA_BIN=java
PROJECT="$ROOT/research/native-core/ghidra-project"
mkdir -p "$OUT"
USERDIR="$ROOT/.tools/ghidra-user/ghidra"
mkdir -p "$USERDIR"
args=("$PROJECT" "native-core" "-process" "target.exe" "-noanalysis"
      "-scriptPath" "$ROOT/tools/ghidra"
      "-postScript" "ExportSelectedFunctions.java" "$OUT" "$@")
OLD_HOME="${JAVA_HOME:-}"; OLD_PATH="$PATH"
export JAVA_HOME="$(dirname "$(dirname "$JAVA_BIN")")"
export PATH="$(dirname "$JAVA_BIN"):$OLD_PATH"
cd "$ROOT"
echo "Running analyzeHeadless with JAVA_HOME=$JAVA_HOME"
"$GHIDRA/support/analyzeHeadless.bat" "${args[@]}" 2>&1 | tail -40
export JAVA_HOME="$OLD_HOME"; export PATH="$OLD_PATH"
