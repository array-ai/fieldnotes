#!/usr/bin/env python3
"""Generates Core/Sources/FieldnoteKit/ModelCatalogData.swift: the optional model
downloads, pinned to exact Hugging Face revisions, with every file's size and
SHA-256.

The app downloads these only when the user taps Download, from these revisions
only, and rejects any file whose hash doesn't match. Bumping a revision is a
deliberate, reviewed change: edit PACKS below and re-run this script.

    Scripts/build-model-manifest.py

LFS files carry their SHA-256 in the Hugging Face API; small non-LFS files
(model.mil, JSON) are downloaded and hashed here.
"""
import hashlib
import json
import os
import urllib.request

# The compile-models workflow's upload to publicarray/fieldnote-models.
FIELDNOTE_MODELS_REVISION = "a834d4d182e589e4a32bda965e33b902f8619ece"

PACKS = [
    {
        "id": "parakeetV3",
        "name": "Parakeet TDT v3 (NVIDIA)",
        "repo": "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        "revision": "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
        "license": "CC-BY-4.0",
        # FluidAudio's v3 file set with the default 6-bit encoder: int4 roughly
        # doubles WER and is slower (FluidAudio EncoderComputePlacement.md).
        "paths": ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
                  "JointDecisionv3.mlmodelc", "parakeet_vocab.json"],
    },
    {
        "id": "parakeetV2",
        "name": "Parakeet TDT v2 English (NVIDIA)",
        "repo": "FluidInference/parakeet-tdt-0.6b-v2-coreml",
        "revision": "ee09c569f73759e6d44c9bd16766f477b2b36d39",
        "license": "CC-BY-4.0",
        # FluidAudio's v2 set (AsrModels.getModelFileNames, default case).
        "paths": ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
                  "JointDecision.mlmodelc", "parakeet_vocab.json"],
    },
    {
        "id": "parakeetTdtCtc110m",
        "name": "Parakeet TDT-CTC 110M English (NVIDIA)",
        "repo": "FluidInference/parakeet-tdt-ctc-110m-coreml",
        "revision": "9bc92ead6e8f17eca92a869fd578ae76842b82ba",
        "license": "CC-BY-4.0",
        # Fused encoder: the preprocessor contains it (ModelNames.ASR.requiredModelsFused).
        "paths": ["Preprocessor.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc",
                  "parakeet_vocab.json"],
    },
    {
        "id": "parakeetCtcWords",
        "name": "Parakeet CTC 110M, for custom words (NVIDIA)",
        "repo": "FluidInference/parakeet-ctc-110m-coreml",
        "revision": "accdafd8cf8a2ff1cabe3c11e54416b405d409aa",
        "license": "CC-BY-4.0",
        # FluidAudio's CTC keyword spotter (CtcModels.loadDirect + the BPE tokenizer):
        # checks the audio before a misheard word becomes a custom one.
        "paths": ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "vocab.json", "tokenizer.json"],
    },
    {
        "id": "nemotronStreaming",
        "name": "Nemotron 3.5 Streaming (NVIDIA)",
        "repo": "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML",
        "revision": "1a41b75758b0337ff67db7d5408280aaaf23074e",
        "license": "OpenMDW-1.1",
        # The Latin-script ship (en, es, fr, it, pt, de: a smaller vocabulary, faster
        # joint) at 2,240 ms chunks, FluidAudio's recommended tier. Loaded with
        # StreamingNemotronMultilingualAsrManager.preloadShared(from: <pack>/latin/2240ms).
        "paths": ["latin/2240ms"],
    },
    {
        "id": "minicpm5",
        "name": "MiniCPM5 1B (Core AI)",
        "repo": "mlboydaisuke/MiniCPM5-1B-CoreAI",
        "revision": "f38d143ec50cb2e54d8388479b919e3b9283943b",
        "license": "Apache-2.0",
        # OpenBMB's MiniCPM5-1B, the portable iOS static export (8-bit palettized,
        # 4,096-token context), compiled on the phone. Loaded from <pack>/ios-static.
        # tokenizer/ must be present: without it the runtime would fetch one from
        # Hugging Face. (Qwen3 1.7B, used before, ran out of memory compiling on an
        # iPhone 16.)
        "paths": ["ios-static"],
    },
] + [
    # MiniCPM5 1B compiled ahead of time by .github/workflows/compile-models.yml,
    # one ready-to-load bundle per Core AI chip family. The app downloads only the
    # one for its own chip (AIModel.deviceArchitectureName).
    {
        "id": "minicpm5" + arch[0].upper() + arch[1:],
        "name": f"MiniCPM5 1B (Core AI, compiled for {arch})",
        "repo": "publicarray/fieldnote-models",
        "revision": FIELDNOTE_MODELS_REVISION,
        "license": "Apache-2.0",
        "paths": [f"ios-{arch}"],
    }
    # h18g isn't a supported iOS 27 target.
    for arch in ["h17g", "h17p", "h18p"]
] + [
    {
        "id": "minicpm5_2b",
        "name": "MiniCPM5 2B (Core AI)",
        "repo": "mlboydaisuke/MiniCPM5-2B-CoreAI",
        "revision": "39db5ff9480e5d80e423889e3bacb7f9e9b9e40f",
        "license": "Apache-2.0",
        # The portable iOS static export (6-bit palettized, 4,096-token context),
        # compiled on the phone, for chips without a compiled build below.
        "paths": ["ios-static"],
    },
    {
        "id": "minicpm5_2bH17p",
        "name": "MiniCPM5 2B (Core AI, compiled for h17p)",
        "repo": "publicarray/fieldnote-models",
        "revision": "5b6e48f1a895a7a74011f98f8aef74a0c99a0707",
        "license": "Apache-2.0",
        "paths": ["minicpm5-2b/ios-h17p"],
    },
] + [
    {
        "id": "pyannoteCommunity1",
        "name": "pyannote community-1",
        "repo": "FluidInference/speaker-diarization-coreml",
        "revision": "1ed7a662fdc7109e36d822db793ee6eebdaf8594",
        "license": "CC-BY-4.0",
        "paths": ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc",
                  "PldaRho.mlmodelc", "plda-parameters.json"],
    },
]


def api(url):
    with urllib.request.urlopen(url) as response:
        return json.load(response)


def tree(repo, revision, path):
    entries = api(f"https://huggingface.co/api/models/{repo}/tree/{revision}/{path}?recursive=true")
    return [e for e in entries if e["type"] == "file"]


def files_for(pack):
    out = []
    for path in pack["paths"]:
        if path.endswith(".json"):
            entries = [e for e in api(f"https://huggingface.co/api/models/{pack['repo']}/tree/{pack['revision']}")
                       if e["path"] == path]
        else:
            entries = tree(pack["repo"], pack["revision"], path)
        for entry in entries:
            if "lfs" in entry and entry["lfs"]:
                sha = entry["lfs"]["oid"]
                size = entry["lfs"]["size"]
            else:
                url = f"https://huggingface.co/{pack['repo']}/resolve/{pack['revision']}/{entry['path']}"
                data = urllib.request.urlopen(url).read()
                sha = hashlib.sha256(data).hexdigest()
                size = len(data)
            out.append((entry["path"], size, sha))
    return sorted(out)


def swift_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


lines = [
    "// Generated by Scripts/build-model-manifest.py. Do not edit by hand.",
    "",
    "extension ModelPack {",
    "    public static let catalog: [ModelPack] = [",
]
for pack in PACKS:
    files = files_for(pack)
    total = sum(size for _, size, _ in files)
    print(f"{pack['id']}: {len(files)} files, {total / 1e6:.1f} MB")
    lines += [
        "        ModelPack(",
        f"            id: .{pack['id']},",
        f"            name: {swift_string(pack['name'])},",
        f"            repo: {swift_string(pack['repo'])},",
        f"            revision: {swift_string(pack['revision'])},",
        f"            license: {swift_string(pack['license'])},",
        "            files: [",
    ]
    for path, size, sha in files:
        lines.append(f"                ModelFile(path: {swift_string(path)}, size: {size}, sha256: {swift_string(sha)}),")
    lines += ["            ]", "        ),"]
lines += ["    ]", "}", ""]

out = os.path.join(os.path.dirname(__file__), "..", "Core", "Sources", "FieldnoteKit", "ModelCatalogData.swift")
with open(out, "w") as f:
    f.write("\n".join(lines))
print("wrote", os.path.normpath(out))
