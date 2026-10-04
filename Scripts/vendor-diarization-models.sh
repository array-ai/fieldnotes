#!/usr/bin/env bash
# Vendors FluidAudio's diarization CoreML models into the app bundle.
#
# Fieldnote makes no outbound requests at runtime (constraint 1), so the models
# cannot be fetched on first use the way FluidAudio's convenience path does. Run this
# once on a build machine, commit or archive the result, and treat the models as a
# dependency with provenance: check the publisher, record the checksum, and review a
# model bump the way you would review any other dependency bump.
#
# Usage: Scripts/vendor-diarization-models.sh <path-to-downloaded-models>
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="${1:-}"
DEST="Resources/DiarizationModels"

if [[ -z "$SOURCE" ]]; then
  cat <<'USAGE'
Give this script a directory containing the FluidAudio diarization CoreML models.

Fetch them on a machine that is allowed to, from the source named in FluidAudio's
own README for the pinned version, then:

  Scripts/vendor-diarization-models.sh ~/Downloads/fluidaudio-models

The script copies them to Resources/DiarizationModels, which xtool.yml copies into
the app bundle, and writes a checksum manifest.
USAGE
  exit 1
fi

mkdir -p "$DEST"
# --exclude keeps the tracked .gitkeep, which --delete would otherwise remove.
rsync -a --delete --exclude .gitkeep "$SOURCE"/ "$DEST"/
find "$DEST" -type f \! -name SHA256SUMS -print0 \
  | sort -z \
  | xargs -0 shasum -a 256 > "$DEST/SHA256SUMS"

echo "Vendored $(find "$DEST" -type f | wc -l | tr -d ' ') files into $DEST"
echo "Checksums written to $DEST/SHA256SUMS. Review before committing."
