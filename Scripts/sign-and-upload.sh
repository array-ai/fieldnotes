#!/usr/bin/env bash
# Signs the unsigned .app xtool packs and uploads it to TestFlight.
#
# xtool's own packer never codesigns anything (dead `sign:` param in
# PackLib/Packer.swift) and its Developer Services client hardcodes
# IOS_APP_DEVELOPMENT / .development everywhere (DeveloperServicesFetchProfileOperation.swift,
# DeveloperServicesFetchCertificateOperation.swift) -- it has no concept of App Store
# distribution. So this script does the whole signing chain itself, independent of
# xtool, using a real Apple Distribution certificate and IOS_APP_STORE profiles
# supplied as secrets.
#
# Required env:
#   DIST_CERT_P12_BASE64, DIST_CERT_PASSWORD   - Apple Distribution cert + key
#   PROVISION_APP_BASE64, PROVISION_WIDGET_BASE64 - IOS_APP_STORE .mobileprovision files,
#                                                    for com.publicarray.fieldnotes and
#                                                    .widgets respectively
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8_BASE64  - App Store Connect API key, for altool
#
# Usage: Scripts/sign-and-upload.sh /path/to/Fieldnote.app [--validate-only]
set -euo pipefail

APP="$1"
VALIDATE_ONLY="${2:-}"
[ -d "$APP" ] || { echo "not a directory: $APP" >&2; exit 1; }
APP=$(cd "$APP" && pwd)

echo "--- checking altool is present before the expensive part runs"
xcrun altool --version

WORKDIR=$(mktemp -d)
trap 'security delete-keychain "$WORKDIR/signing.keychain-db" 2>/dev/null || true; rm -rf "$WORKDIR"' EXIT

# --- Temporary keychain for the distribution identity ---------------------
KEYCHAIN="$WORKDIR/signing.keychain-db"
KEYCHAIN_PASSWORD=$(openssl rand -base64 24)
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

echo "$DIST_CERT_P12_BASE64" | openssl base64 -d -A -out "$WORKDIR/dist.p12"
security import "$WORKDIR/dist.p12" -k "$KEYCHAIN" -P "$DIST_CERT_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

# Old keychains stay in the search list on a fresh runner, but be explicit anyway.
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN" | grep -o '"Apple Distribution:[^"]*"' | head -1 | tr -d '"')
[ -n "$IDENTITY" ] || { echo "no Apple Distribution identity found in the imported .p12" >&2; exit 1; }
echo "--- signing identity: $IDENTITY"

# --- Embed provisioning profiles and derive each bundle's entitlements ----
# The profile is the source of truth for entitlements: it's what the App ID's
# capabilities actually grant, so extracting from it (rather than hand-merging
# Config/*.entitlements) is what keeps codesign from producing something the
# profile itself would reject.
embed_profile() {
  local base64_var="$1" bundle_dir="$2" entitlements_out="$3"
  echo "${!base64_var}" | openssl base64 -d -A -out "$bundle_dir/embedded.mobileprovision"
  security cms -D -i "$bundle_dir/embedded.mobileprovision" > "$WORKDIR/profile.plist"
  /usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$WORKDIR/profile.plist" > "$entitlements_out"
}

embed_profile PROVISION_APP_BASE64 "$APP" "$WORKDIR/app.entitlements.plist"

# The profile is only as good as what the App ID's capabilities grant. If Background
# Tasks (continued processing) isn't enabled on the App ID in the developer portal,
# the profile silently omits these keys and background summarization dies at
# runtime -- signed, uploaded, shipped, broken, with nothing here to say why. Fail
# the build instead.
for key in \
  "com.apple.developer.background-tasks.continued-processing.inference" \
  "com.apple.developer.background-tasks.continued-processing.gpu"; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$WORKDIR/app.entitlements.plist" >/dev/null 2>&1 || {
    echo "error: the app's IOS_APP_STORE profile does not grant '$key'." >&2
    echo "Enable Background Tasks (continued processing) for com.publicarray.fieldnotes" >&2
    echo "in Certificates, Identifiers & Profiles, then regenerate the profile." >&2
    exit 1
  }
done

WIDGET_APPEX=$(find "$APP/PlugIns" -maxdepth 1 -name "*.appex" | head -1)
[ -n "$WIDGET_APPEX" ] || { echo "no .appex found under $APP/PlugIns" >&2; exit 1; }
embed_profile PROVISION_WIDGET_BASE64 "$WIDGET_APPEX" "$WORKDIR/widget.entitlements.plist"

# --- Patch Info.plist metadata Xcode normally stamps in, which a bare `swift build`
# never produces -- App Store Connect's binary validator requires both. Must happen
# before codesign: editing a plist after signing invalidates the signature.
IOS_SDK_VERSION=$(xcrun -sdk iphoneos --show-sdk-version)

set_plist_string() {
  local plist="$1" key="$2" value="$3"
  /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist"
}

for plist in "$APP/Info.plist" "$WIDGET_APPEX/Info.plist"; do
  set_plist_string "$plist" DTPlatformName iphoneos
  set_plist_string "$plist" DTPlatformVersion "$IOS_SDK_VERSION"
  set_plist_string "$plist" DTSDKName "iphoneos$IOS_SDK_VERSION"
done

# PackLib/Packer.swift (xtool) only sets UIRequiredDeviceCapabilities on the main
# app product (gated on `product.type == .application`), never on extensions --
# App Store Connect requires it on every 64-bit binary in the bundle.
/usr/libexec/PlistBuddy -c "Print :UIRequiredDeviceCapabilities" "$WIDGET_APPEX/Info.plist" >/dev/null 2>&1 || {
  /usr/libexec/PlistBuddy -c "Add :UIRequiredDeviceCapabilities array" "$WIDGET_APPEX/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :UIRequiredDeviceCapabilities:0 string arm64" "$WIDGET_APPEX/Info.plist"
}

# --- App icon -----------------------------------------------------------
# App Store Connect requires CFBundleIconName plus a compiled asset catalog for
# any iOS 11+ SDK build; xtool's iconPath support only emits the legacy
# CFBundleIconFile (a loose PNG, no catalog), which doesn't satisfy ASC's
# validator. xtool.yml has no iconPath support wired up at all, so this compiles
# Resources/AppIcon.xcassets (checked into the repo) straight with actool
# instead, independent of xtool's own packing.
#
# Uses the modern single-size icon format (Xcode 14+/actool auto-scales from one
# 1024x1024 source) rather than enumerating every legacy @2x/@3x combination.
mkdir -p "$WORKDIR/compiled-assets"
xcrun actool \
  --output-format human-readable-text \
  --notices --warnings \
  --platform iphoneos \
  --minimum-deployment-target 27.0 \
  --target-device iphone \
  --app-icon AppIcon \
  --output-partial-info-plist "$WORKDIR/icon-partial.plist" \
  --compile "$WORKDIR/compiled-assets" \
  Resources/AppIcon.xcassets

cp "$WORKDIR/compiled-assets/Assets.car" "$APP/Assets.car"
/usr/libexec/PlistBuddy -c "Merge $WORKDIR/icon-partial.plist :" "$APP/Info.plist"

# --- Sign innermost-out: nested frameworks, then the extension, then the app ---
if [ -d "$APP/Frameworks" ]; then
  find "$APP/Frameworks" -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) | while read -r fw; do
    codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp "$fw"
  done
fi

codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp \
  --entitlements "$WORKDIR/widget.entitlements.plist" "$WIDGET_APPEX"

codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp \
  --entitlements "$WORKDIR/app.entitlements.plist" "$APP"

echo "--- verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

# --- Package as .ipa -------------------------------------------------------
# ditto, not cp -R: it's what Apple's own tooling uses to copy a signed bundle
# without perturbing the signature (matters if FluidAudio turns out to embed a
# dynamic framework in Frameworks/).
IPA_ROOT="$WORKDIR/ipa"
mkdir -p "$IPA_ROOT/Payload"
ditto "$APP" "$IPA_ROOT/Payload/$(basename "$APP")"
IPA_PATH="$WORKDIR/Fieldnote.ipa"
(cd "$IPA_ROOT" && zip -qry "$IPA_PATH" Payload)
echo "--- packaged $IPA_PATH ($(du -h "$IPA_PATH" | cut -f1))"

# --- Upload (or validate) with TestFlight -----------------------------------
mkdir -p ~/.appstoreconnect/private_keys
echo "$ASC_KEY_P8_BASE64" | openssl base64 -d -A -out ~/.appstoreconnect/private_keys/AuthKey_"$ASC_KEY_ID".p8

ALTOOL_ACTION="--upload-app"
if [ "$VALIDATE_ONLY" = "--validate-only" ]; then
  ALTOOL_ACTION="--validate-app"
  echo "--- --validate-only requested: checking auth, app record and binary without publishing"
fi

xcrun altool "$ALTOOL_ACTION" \
  --type ios \
  --file "$IPA_PATH" \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID"

if [ "$ALTOOL_ACTION" = "--validate-app" ]; then
  echo "--- validated, not uploaded (re-run without --validate-only to publish)"
else
  echo "--- uploaded to TestFlight"
fi
