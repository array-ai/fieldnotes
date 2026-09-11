#!/usr/bin/env bash
# Regenerate Fieldnote.xcodeproj from project.yml.
# Requires XcodeGen: brew install xcodegen
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen"; exit 1; }
xcodegen generate
echo "Generated Fieldnote.xcodeproj"
