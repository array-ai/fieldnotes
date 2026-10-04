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
at all (constraint 1). So they are vendored at build time instead:

```sh
Scripts/vendor-diarization-models.sh ~/Downloads/fluidaudio-models
```

That writes `DiarizationModels/SHA256SUMS` alongside them. Treat a model bump like any
other dependency bump: check the publisher, compare the checksum, and have a reason to
trust the source. "No network traffic" is not the same as "no risk".

Without this directory populated, `DiarizationModelProvider.bundledModels()` throws and
the diarization stage fails loudly. That is deliberate: the alternative is a silent
fallback that reaches for the network.

CI does the equivalent automatically, cached by `actions/cache` (see `app.yml` /
`release.yml`): `Scripts/fetch-diarization-models.sh` downloads exactly the files
`DiarizationModelProvider` loads from **pinned** HuggingFace revisions (not `main`) and
hands them to `vendor-diarization-models.sh`. Its file list is also the exact layout a
manual vendor has to reproduce. The CI cache is keyed on the script's hash, so changing
a pin or a file list invalidates it. Bumping the model means bumping that
revision pin deliberately, the same review as above -- not floating.
