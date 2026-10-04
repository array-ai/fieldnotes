#!/usr/bin/env bash
# Downloads the diarization CoreML models (all three DiarizationMethods) from
# pinned HuggingFace revisions, to hand to vendor-diarization-models.sh. CI and
# local builds use it alike; the pins below are what gets reviewed.
#
# Usage: Scripts/fetch-diarization-models.sh <dest-dir>
set -euo pipefail

DEST="${1:?usage: fetch-diarization-models.sh <dest-dir>}"

# Pinned, not "main": a model bump should be a deliberate, reviewed change here,
# the same way a dependency version bump is (see Resources/README.md).
#
# Three methods, all selectable in Settings (DiarizationMethod):
#
#   - pyannote 3.1 (legacy) and pyannote community-1 both come from
#     FluidInference/speaker-diarization-coreml (pyannote finetunes, CC-BY-4.0),
#     confirmed against the `diarizer` case in FluidAudio's ModelNames.swift.
#   - Nemotron 3 comes from FluidInference/nemotron-3-diarization-coreml, a CoreML
#     conversion of nvidia/Nemotron-3-Diarization (OpenMDW-1.1).
PYANNOTE_REPO="FluidInference/speaker-diarization-coreml"
PYANNOTE_REVISION="1ed7a662fdc7109e36d822db793ee6eebdaf8594"
NEMOTRON_REPO="FluidInference/nemotron-3-diarization-coreml"
NEMOTRON_REVISION="25a90f97f254428d4b30374b76af9c74fdee8327"

# Only what DiarizationModelProvider loads; everything else in the HF repos
# (mlpackages/, benchmark plots, other presets) is not fetched.
mlmodelc() {
  local name="$1"
  echo "$name/coremldata.bin"
  echo "$name/analytics/coremldata.bin"
  echo "$name/model.mil"
  echo "$name/weights/weight.bin"
}

PYANNOTE_FILES=(
  # pyannote 3.1 (legacy): DiarizationModelProvider.segmentationFile / .embeddingFile
  $(mlmodelc pyannote_segmentation.mlmodelc)
  "pyannote_segmentation.mlmodelc/metadata.json"
  $(mlmodelc wespeaker_v2.mlmodelc)
  "wespeaker_v2.mlmodelc/metadata.json"
  # pyannote community-1: FluidAudio's ModelNames.OfflineDiarizer
  $(mlmodelc Segmentation.mlmodelc)
  "Segmentation.mlmodelc/metadata.json"
  $(mlmodelc FBank.mlmodelc)
  "FBank.mlmodelc/metadata.json"
  $(mlmodelc Embedding.mlmodelc)
  "Embedding.mlmodelc/metadata.json"
  $(mlmodelc PldaRho.mlmodelc)
  "PldaRho.mlmodelc/metadata.json"
  "plda-parameters.json"
)

fetch() {
  local repo="$1" revision="$2" remote="$3" local_path="$4"
  mkdir -p "$DEST/$(dirname "$local_path")"
  echo "Fetching $repo/$remote"
  curl -sSfL "https://huggingface.co/$repo/resolve/$revision/$remote" -o "$DEST/$local_path"
}

mkdir -p "$DEST"
for file in "${PYANNOTE_FILES[@]}"; do
  fetch "$PYANNOTE_REPO" "$PYANNOTE_REVISION" "$file" "$file"
done

# Nemotron 3, preset c128-split-w8a8 (DiarizationModelProvider.nemotronPreset).
# Flattened into Nemotron3/: Nemotron3Models.load wants the .mlmodelc and both .bin
# assets side by side, while the HF repo keeps the model under split/. These
# .mlmodelc bundles have no metadata.json.
NEMOTRON_MODEL="Nemotron3Diarizer_c128_split_w8a8.mlmodelc"
for file in $(mlmodelc "$NEMOTRON_MODEL"); do
  fetch "$NEMOTRON_REPO" "$NEMOTRON_REVISION" "split/$file" "Nemotron3/$file"
done
for file in learnable_sil_emb.bin pre_encode_proj_t.bin; do
  fetch "$NEMOTRON_REPO" "$NEMOTRON_REVISION" "$file" "Nemotron3/$file"
done

echo "Fetched $(find "$DEST" -type f | wc -l | tr -d ' ') files"
