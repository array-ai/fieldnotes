# Resources

Copied into the app bundle root by xtool (`resources:` in `xtool.yml`).

## DiarizationModels

The speaker-diarization CoreML models, one set per method in Settings → Speaker
identification (`DiarizationMethod`). **Not committed** — they are large binaries with
their own provenance, and they are fetched, not authored here.

| Method | Files | Source | License |
|---|---|---|---|
| Nemotron 3 (default) | `Nemotron3/` — `Nemotron3Diarizer_c128_split_w8a8.mlmodelc`, `learnable_sil_emb.bin`, `pre_encode_proj_t.bin` (~95 MB) | [FluidInference/nemotron-3-diarization-coreml](https://huggingface.co/FluidInference/nemotron-3-diarization-coreml), converted from [nvidia/Nemotron-3-Diarization](https://huggingface.co/nvidia/Nemotron-3-Diarization) | OpenMDW-1.1 |
| pyannote community-1 | `Segmentation`, `FBank`, `Embedding`, `PldaRho` `.mlmodelc`, `plda-parameters.json` | [FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml) | CC-BY-4.0 |
| pyannote 3.1 (legacy) | `pyannote_segmentation.mlmodelc`, `wespeaker_v2.mlmodelc` | same repo | CC-BY-4.0 |

All three are already CoreML conversions; nothing is converted here. The Nemotron
files are flattened into `Nemotron3/` because `Nemotron3Models.load` wants the model
and both `.bin` assets in one directory, while the Hugging Face repo keeps the model
under `split/`.

Fieldnote never downloads them at runtime, because the app makes no outbound requests
at all. So they are vendored at build time instead, from pinned Hugging Face revisions
(not `main`):

```sh
Scripts/fetch-diarization-models.sh /tmp/fieldnote-models
Scripts/vendor-diarization-models.sh /tmp/fieldnote-models
```

The fetch script downloads exactly the files `DiarizationModelProvider` loads, and the
vendor script copies them here and writes `SHA256SUMS`. CI runs the same two scripts,
cached by `actions/cache` keyed on the fetch script's hash, so changing a pin or a file
list invalidates the cache.

Treat a model bump like any other dependency bump: change the revision pin
deliberately, check the publisher, and compare the checksums. "No network traffic" is
not the same as "no risk".

If a model is missing, `DiarizationModelProvider` throws and the diarization stage fails
loudly. That is deliberate: the alternative is a silent fallback that reaches for the
network.
