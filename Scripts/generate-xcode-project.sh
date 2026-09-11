#!/usr/bin/env bash
# Generates an Xcode workspace for the package, for working in Xcode itself.
#
# xtool builds the app from the SwiftPM package directly; this produces the
# equivalent Xcode workspace (xtool/Fieldnote.xcworkspace) for the debugger,
# Instruments, view debugging and on-device runs from Xcode.
#
# The generated workspace is disposable: it is regenerated from Package.swift and
# xtool.yml, and is gitignored. Never edit it by hand — edit the manifests.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xtool >/dev/null || {
  echo "xtool not found. Install it: brew install xtool-org/tap/xtool" >&2
  exit 1
}

xtool dev generate-xcode-project
echo
echo "Open it with:  open xtool/Fieldnote.xcworkspace"
