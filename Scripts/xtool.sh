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

# swift-crypto (pulled in by Apple's coreai-models via swift-transformers) declares
# a privacy-manifest resource on its CXKCPShims target, but only builds that target
# for non-Apple platforms. xtool reads the manifest, expects the target's resource
# bundle, and fails packing when SwiftPM never produced it. Nothing in it is used on
# iOS, so provide the bundle swift-crypto would have: its privacy manifest plus a
# minimal Info.plist. Harmless if SwiftPM ever starts building it.
SHIMS_SOURCE=".build/checkouts/swift-crypto/Sources/CXKCPShims/PrivacyInfo.xcprivacy"
[ -f "$SHIMS_SOURCE" ] || "$REAL_SWIFT_PACKAGE" resolve >/dev/null
# Both product layouts: SwiftPM's native one, and the swiftbuild one newer xtool
# versions select themselves (their own --build-system flag overrides the shim's).
for dir in .build/arm64-apple-ios/debug .build/arm64-apple-ios/release \
           .build/out/Products/Debug-iphoneos .build/out/Products/Release-iphoneos; do
  bundle="$dir/swift-crypto_CXKCPShims.bundle"
  mkdir -p "$bundle"
  [ -f "$SHIMS_SOURCE" ] && cp "$SHIMS_SOURCE" "$bundle/PrivacyInfo.xcprivacy"
  cat > "$bundle/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>swift-crypto.CXKCPShims.resources</string>
	<key>CFBundleName</key>
	<string>swift-crypto_CXKCPShims</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
</dict>
</plist>
PLIST
done

SWIFTPM_CUSTOM_BIN_DIR="$SHIM_DIR" exec xtool "$@"
