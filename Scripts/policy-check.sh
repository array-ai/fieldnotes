#!/usr/bin/env bash
# Fieldnote policy checks. Same rules as Tests/FieldnoteTests/PolicyTests.swift, run
# without a Mac so they gate every push.
#
# These are "this code does not exist" rules. They are cheap to break by accident and
# impossible to notice afterwards, which is why they are enforced mechanically.
set -uo pipefail
cd "$(dirname "$0")/.."

SOURCES=(Fieldnote FieldnoteWidgets)
FAILED=0

# Greps source lines, ignoring whole-line comments so a rule can be described in a
# doc comment without tripping itself.
scan() {
  local needle="$1"
  grep -rn --include='*.swift' -F -- "$needle" "${SOURCES[@]}" 2>/dev/null \
    | grep -vE ':[[:space:]]*(//|///|\*)' \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//'
}

fail() {
  echo "FAIL: $1"
  echo "$2" | sed 's/^/      /'
  FAILED=1
}

check_absent() {
  local needle="$1" reason="$2" exclude="${3:-}"
  local hits
  hits="$(scan "$needle")"
  if [[ -n "$exclude" ]]; then
    hits="$(printf '%s\n' "$hits" | grep -v -- "$exclude" || true)"
  fi
  if [[ -n "$hits" ]]; then
    fail "$reason" "$hits"
  else
    echo "ok: $reason"
  fi
}

echo "== Constraint 6: every Foundation Models session is pinned on-device"
check_absent "LanguageModelSession(" \
  "sessions are constructed only in OnDeviceModel" \
  "Fieldnote/Summarisation/OnDeviceModel.swift"

echo
echo "== Constraint 7: no third-party model providers"
for needle in ": LanguageModel " ": LanguageModel," ": LanguageModel {"; do
  check_absent "$needle" "no LanguageModel conformance ($needle)"
done

echo
echo "== Constraint 8 / spec 4.8: no App Intents, no semantic indexing"
for needle in "import AppIntents" "IndexedEntity" "AssistantEntity" "AssistantIntent" \
              "indexingKey" "AppShortcutsProvider" "ViewAnnotation" ": AppIntent" "EntityQuery"; do
  check_absent "$needle" "no $needle"
done

echo
echo "== Constraint 1: no networking code at all"
for needle in "URLSession" "URLRequest" "NSURLConnection" "import Network" "NWConnection" \
              "CFReadStream" "WKWebView" "URLProtocol"; do
  check_absent "$needle" "no $needle"
done

echo
echo "== Entitlements"
ENTITLEMENTS=Fieldnote/Resources/Fieldnote.entitlements
if grep -q "com.apple.developer.background-tasks.continued-processing.inference" "$ENTITLEMENTS"; then
  echo "ok: continued-processing inference entitlement present"
else
  fail "continued-processing inference entitlement missing" "$ENTITLEMENTS"
fi
for key in "com.apple.security.network.client" "com.apple.security.network.server"; do
  if grep -q "<key>$key</key>" "$ENTITLEMENTS"; then
    fail "network entitlement $key must not be granted" "$ENTITLEMENTS"
  else
    echo "ok: no $key entitlement"
  fi
done

echo
if [[ "$FAILED" -ne 0 ]]; then
  echo "Policy checks FAILED."
  exit 1
fi
echo "All policy checks passed."
