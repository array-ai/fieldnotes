#!/usr/bin/env bash
# Downloads the bundled speaker model (Nemotron 3) from a pinned HuggingFace
# revision, to hand to vendor-diarization-models.sh. CI and
# local builds use it alike; the pins below are what gets reviewed.
#
# Usage: Scripts/fetch-diarization-models.sh <dest-dir>
set -euo pipefail

DEST="${1:?usage: fetch-diarization-models.sh <dest-dir>}"

# Pinned, not "main": a model bump should be a deliberate, reviewed change here,
# the same way a dependency version bump is (see Resources/README.md).
#
# Only Nemotron 3 is bundled: FluidInference/nemotron-3-diarization-coreml, a
# CoreML conversion of nvidia/Nemotron-3-Diarization (OpenMDW-1.1). The pyannote
# methods and Parakeet are optional in-app downloads, pinned and hashed in
# Core/Sources/FieldnoteKit/ModelCatalogData.swift (Scripts/build-model-manifest.py).
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

fetch() {
  local repo="$1" revision="$2" remote="$3" local_path="$4"
  mkdir -p "$DEST/$(dirname "$local_path")"
  echo "Fetching $repo/$remote"
  curl -sSfL "https://huggingface.co/$repo/resolve/$revision/$remote" -o "$DEST/$local_path"
}

mkdir -p "$DEST"

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
