#!/usr/bin/env bash
# Downloads FluidAudio's diarization CoreML models from a pinned HuggingFace
# revision, for CI to hand to vendor-diarization-models.sh.
#
# CI-only. A human vendoring models locally should fetch and vet them manually
# instead (see Resources/README.md) -- this script exists so CI doesn't have to,
# on the strength of the pin below having already been reviewed once.
#
# Usage: Scripts/fetch-diarization-models.sh <dest-dir>
set -euo pipefail

DEST="${1:?usage: fetch-diarization-models.sh <dest-dir>}"

# Pinned, not "main": a model bump should be a deliberate, reviewed change here,
# the same way a dependency version bump is (see Resources/README.md). Repo is
# FluidInference/speaker-diarization-coreml (a pyannote/speaker-diarization-
# community-1 finetune, CC-BY-4.0), confirmed against the `diarizer` case in
# FluidAudio's own ModelNames.swift.
REPO="FluidInference/speaker-diarization-coreml"
REVISION="1ed7a662fdc7109e36d822db793ee6eebdaf8594"

# Matches DiarizationModelProvider.segmentationFile / .embeddingFile exactly --
# those two filenames are the actual runtime dependency; everything else in the
# HF repo (mlpackages/, benchmark plots, wespeaker_int8, etc.) is not fetched.
FILES=(
  "pyannote_segmentation.mlmodelc/coremldata.bin"
  "pyannote_segmentation.mlmodelc/analytics/coremldata.bin"
  "pyannote_segmentation.mlmodelc/metadata.json"
  "pyannote_segmentation.mlmodelc/model.mil"
  "pyannote_segmentation.mlmodelc/weights/weight.bin"
  "wespeaker_v2.mlmodelc/coremldata.bin"
  "wespeaker_v2.mlmodelc/analytics/coremldata.bin"
  "wespeaker_v2.mlmodelc/metadata.json"
  "wespeaker_v2.mlmodelc/model.mil"
  "wespeaker_v2.mlmodelc/weights/weight.bin"
)

mkdir -p "$DEST"
for file in "${FILES[@]}"; do
  mkdir -p "$DEST/$(dirname "$file")"
  echo "Fetching $file"
  curl -sSfL "https://huggingface.co/$REPO/resolve/$REVISION/$file" -o "$DEST/$file"
done

echo "Fetched $(find "$DEST" -type f | wc -l | tr -d ' ') files from $REPO@$REVISION"
