#!/usr/bin/env bash
# Prints the real declarations of the iOS SDK APIs Fieldnote depends on.
#
# These frameworks ship binary .swiftmodule files with no textual .swiftinterface,
# so the module has to be dumped rather than read. Temporary: this exists to match
# iOS 27 API shapes exactly instead of guessing one CI round-trip at a time.
#
# Usage: Scripts/dump-sdk-api.sh [module ...]
set -uo pipefail

SDK=$(xcrun -sdk iphoneos --show-sdk-path)
TARGET=arm64-apple-ios27.0
MODULES=("${@:-}")
[ -z "${MODULES[0]:-}" ] && MODULES=(Speech FoundationModels BackgroundTasks)

echo "SDK=$SDK"
echo "TARGET=$TARGET"

for module in "${MODULES[@]}"; do
  echo "=================== $module"
  OUT="/tmp/$module.json"
  if xcrun swift-api-digester -dump-sdk -module "$module" \
      -target "$TARGET" -sdk "$SDK" -o "$OUT" 2>"/tmp/$module.err"; then
    echo "--- dumped $(wc -c < "$OUT") bytes"
    python3 - "$OUT" <<'PY'
import json, sys

INTERESTING = (
    "AssetInventory", "ContextualStrings", "AnalysisContext",
    "GenerationError", "guardrail", "exceededContext",
    "submit", "reserve", "allocate", "deallocate",
)

def walk(node, depth=0):
    name = node.get("printedName") or node.get("name") or ""
    kind = node.get("declKind", "")
    if any(needle.lower() in name.lower() for needle in INTERESTING):
        print(f"{'  ' * min(depth, 4)}{kind or '?'}: {name}")
    for child in node.get("children", []) or []:
        walk(child, depth + 1)

walk(json.load(open(sys.argv[1])))
PY
  else
    echo "--- swift-api-digester failed; falling back to strings"
    tail -3 "/tmp/$module.err"
    MODULE_DIR=$(find "$SDK" -name "$module.swiftmodule" -type d 2>/dev/null | head -1)
    echo "--- module dir: $MODULE_DIR"
    [ -n "$MODULE_DIR" ] || continue
    BINARY=$(find "$MODULE_DIR" -name "arm64-apple-ios.swiftmodule" | head -1)
    [ -n "$BINARY" ] || BINARY=$(find "$MODULE_DIR" -type f | head -1)
    echo "--- strings from: $BINARY"
    strings "$BINARY" \
      | grep -iE "assetinventory|contextualstrings|allocat|deallocat|reserv|guardrail|submittask" \
      | sort -u | head -40
  fi
done
