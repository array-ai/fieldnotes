#!/usr/bin/env bash
# Type-checks the app on Linux, as far as Linux can, and prints only the errors a
# change introduced.
#
# Why this exists
# ---------------
# The app can't be fully compiled on Linux: the iOS SDK ships Apple's macros as
# Mac-only plugins. xtool 1.20 and later put open replacements for some of them in
# the Darwin SDK it builds (OpenAppleMacros: @State, @Generable, @Guide), so views
# and the summariser compile properly. SwiftData's (@Model, @ModelActor) have no
# replacement yet, so Models.swift and MeetingStore.swift still fail, with a
# hundred-odd follow-on errors. The only full compile is the release build on a
# macOS runner, which is slow and billed.
#
# Those errors are the same before and after a change, though. So this compiles the
# working tree and a clean checkout of a base commit, and reports the errors the
# working tree has that the base doesn't. Errors are matched by file and message,
# not line number, so moving code doesn't count as a new error.
#
# What it can't see: a mistake in code the compiler already gives up on. That is
# most of the two SwiftData files, and, with an SDK from xtool before 1.20 (no
# macro replacements at all), the big view bodies, which are then listed at the
# end. The release build is still the final check.
#
# Usage: Scripts/typecheck.sh [base]
#        base: the commit to compare against. Default HEAD, i.e. "what did my
#        uncommitted changes break?". After committing, pass the commit before
#        your work, e.g. Scripts/typecheck.sh origin/main
#
# The first run against a new base builds it from scratch in .build/typecheck
# (several minutes); its errors are then kept, so later runs only compile the
# working tree.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

BASE_REF=${1:-HEAD}
BASE_SHA=$(git rev-parse --verify --quiet "$BASE_REF^{commit}") || {
  echo "Not a commit: $BASE_REF" >&2
  exit 2
}

SDK=arm64-apple-ios
TARGETS=(Fieldnote FieldnoteWidgets)
CACHE="$ROOT/.build/typecheck"
WORKTREE="$CACHE/base"
mkdir -p "$CACHE"

swift sdk list 2>/dev/null | grep -q darwin || {
  echo "No Darwin Swift SDK installed (swift sdk list). Run: xtool setup" >&2
  exit 2
}

# Compiles each target in the given checkout and writes its errors to the given
# file, one per line, as "path:line:col: error: message" with the path relative to
# the checkout. The build always fails here (the macros); only the errors matter.
collect_errors() {
  local dir=$1 out=$2 log=$2.log
  : > "$log"
  for target in "${TARGETS[@]}"; do
    (cd "$dir" && swift build --swift-sdk "$SDK" --build-system native --target "$target") >> "$log" 2>&1 || true
  done
  { grep -E "^/.*\.swift:[0-9]+:[0-9]+: error: " "$log" || true; } \
    | sed -e "s#^$dir/##" \
    | sort -u > "$out"
  # No errors at all means the compiler never got to the app's sources.
  if [ ! -s "$out" ] && ! grep -q "Compiling\|Build complete" "$log"; then
    echo "The build in $dir didn't reach the compiler:" >&2
    tail -15 "$log" >&2
    exit 2
  fi
}

# The base's errors depend on the SDK as well as the commit: a rebuilt SDK (new
# xtool, new Xcode) changes which macros expand.
SDK_STAMP=$(cat "$HOME/.swiftpm/swift-sdks/darwin.artifactbundle/darwin-sdk-version.txt" 2>/dev/null || echo unknown)
SDK_KEY=$(printf '%s' "$SDK_STAMP" | cksum | cut -d' ' -f1)
BASE_ERRORS="$CACHE/base-$BASE_SHA-$SDK_KEY.txt"
if [ ! -f "$BASE_ERRORS" ]; then
  echo "Building the base ($(git log -1 --format='%h %s' "$BASE_SHA" | cut -c1-70)) once…" >&2
  if [ -e "$WORKTREE/.git" ]; then
    git -C "$WORKTREE" checkout --quiet --detach "$BASE_SHA"
  else
    git worktree prune
    git worktree add --quiet --detach "$WORKTREE" "$BASE_SHA"
  fi
  collect_errors "$WORKTREE" "$BASE_ERRORS.tmp"
  mv "$BASE_ERRORS.tmp" "$BASE_ERRORS"
  # Keep the last few bases; the rest are stale.
  ls -t "$CACHE"/base-*.txt 2>/dev/null | tail -n +6 | xargs -r rm -f
fi

echo "Compiling the working tree…" >&2
NOW_ERRORS="$CACHE/now.txt"
collect_errors "$ROOT" "$NOW_ERRORS"

# An error's identity: its file and message, without the line and column.
key='{ line = $0; sub(/:[0-9]+:[0-9]+: error: /, ": ", line); print line }'

# New: more errors with the same file and message than the base has. All of the
# working tree's errors with that identity are printed, since which of them is the
# new one can't be told apart.
NEW=$(awk -v base="$BASE_ERRORS" '
  function ident(text) { sub(/:[0-9]+:[0-9]+: error: /, ": ", text); return text }
  BEGIN { while ((getline line < base) > 0) before[ident(line)]++ }
  { id = ident($0); now[id]++; lines[id] = lines[id] $0 "\n" }
  END {
    for (id in now) if (now[id] > before[id]) {
      printf "%s", lines[id]
      if (before[id] > 0) printf "    (%d of these %d are new; the base has %d)\n", now[id] - before[id], now[id], before[id]
    }
  }' "$NOW_ERRORS" | sort -t: -k1,1 -k2,2n)

# The view bodies the compiler gives up on, where a mistake would go unseen.
BLIND=$(grep "unable to type-check this expression" "$NOW_ERRORS" | sed -E 's/^([^:]+:[0-9]+):.*/\1/' || true)
CHANGED=$(git diff --name-only "$BASE_SHA" -- Sources | tr '\n' ' ')

echo
if [ -n "$NEW" ]; then
  echo "New errors since $(git rev-parse --short "$BASE_SHA"):"
  echo
  echo "$NEW"
  STATUS=1
else
  echo "No new errors since $(git rev-parse --short "$BASE_SHA") ($(wc -l < "$NOW_ERRORS") known macro errors in $(sed -E 's/:[0-9]+:[0-9]+: error: .*//' "$NOW_ERRORS" | sort -u | wc -l) files, same as the base)."
  STATUS=0
fi

if [ -n "$BLIND" ]; then
  echo
  echo "Not checked: the compiler gives up on these view bodies without the macros,"
  echo "so a mistake inside one only shows in the release build. An SDK built by"
  echo "xtool 1.20 or later (xtool sdk install Xcode.xip) expands them."
  for place in $BLIND; do
    file=${place%%:*}
    case " $CHANGED " in
      *" $file "*) echo "  $place  (changed since the base)" ;;
      *) echo "  $place" ;;
    esac
  done
fi

exit $STATUS
