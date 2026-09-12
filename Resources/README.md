# Resources

Copied into the app bundle root by xtool (`resources:` in `xtool.yml`).

## DiarizationModels

FluidAudio's speaker-diarization CoreML models. **Not committed** — they are large
binaries with their own provenance, and they are fetched, not authored here.

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
`release.yml`): `Scripts/fetch-diarization-models.sh` downloads the exact two files
`DiarizationModelProvider` needs from a **pinned** HuggingFace revision (not `main`) and
hands them to `vendor-diarization-models.sh`. Bumping the model means bumping that
revision pin deliberately, the same review as above -- not floating.
