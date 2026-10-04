#!/usr/bin/env bash
# Runs xtool with SwiftPM's *native* build system.
#
# Why this wrapper exists
# -----------------------
# xtool's packer copies the built products out of `.build/<triple>/<config>`, which
# is where SwiftPM's native build system puts them. As of Swift 6.4 (Xcode 27),
# SwiftPM defaults to the `swiftbuild` build system instead, which writes to
# `.build/out/Products/<Config>-<platform>`. The compile succeeds and then packing
# fails looking for things like `FluidAudio_FluidAudio.bundle`.
#
# xtool has no flag to pass build options through, but it does honour
# SWIFTPM_CUSTOM_BIN_DIR: when set, it invokes `<dir>/swift-build` and
# `<dir>/swift-package` directly. So this points that at two shims that add
# `--build-system native` and then hand off to the real tools.
#
# Remove this wrapper once xtool understands the swiftbuild layout; nothing in the
# app depends on it.
#
# Usage: Scripts/xtool.sh dev build
#        Scripts/xtool.sh dev run
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xtool >/dev/null || {
  echo "xtool not found. Install it: brew install xtool-org/tap/xtool" >&2
  exit 1
}

# xcrun on macOS; on Linux there is no xcrun and the tools are just on PATH.
if command -v xcrun >/dev/null; then
  REAL_SWIFT_BUILD=$(xcrun -f swift-build)
  REAL_SWIFT_PACKAGE=$(xcrun -f swift-package)
else
  REAL_SWIFT_BUILD=$(command -v swift-build)
  REAL_SWIFT_PACKAGE=$(command -v swift-package)
fi

SHIM_DIR="${TMPDIR:-/tmp}/fieldnote-swiftpm-shim"
mkdir -p "$SHIM_DIR"

# The shims unset the variable before exec'ing so only xtool's own invocations are
# redirected — SwiftPM reads the same variable to find its helper tools.
cat > "$SHIM_DIR/swift-build" <<EOF
#!/usr/bin/env bash
unset SWIFTPM_CUSTOM_BIN_DIR
exec "$REAL_SWIFT_BUILD" --build-system native "\$@"
EOF

cat > "$SHIM_DIR/swift-package" <<EOF
#!/usr/bin/env bash
unset SWIFTPM_CUSTOM_BIN_DIR
exec "$REAL_SWIFT_PACKAGE" "\$@"
EOF

chmod +x "$SHIM_DIR/swift-build" "$SHIM_DIR/swift-package"

SWIFTPM_CUSTOM_BIN_DIR="$SHIM_DIR" exec xtool "$@"
