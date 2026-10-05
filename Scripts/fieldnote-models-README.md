---
license: apache-2.0
base_model: openbmb/MiniCPM5-1B
pipeline_tag: text-generation
library_name: coreai
tags:
  - core-ai
  - ios
  - on-device
  - minicpm5
---

# Fieldnote models

MiniCPM5 1B compiled ahead of time for Apple's Core AI, one ready-to-load bundle per
iPhone chip family. Used by [Fieldnote](https://github.com/array-ai/fieldnotes), an
on-device meeting recorder, to write meeting notes without compiling the model on
the phone (the on-phone compile of a larger model ran an iPhone 16 out of memory).

## Bundles

| Folder | Core AI architecture | Phones |
|---|---|---|
| `ios-h17g` | h17g | iPhone 16 family |
| `ios-h17p` | h17p | iPhone 16 family |
| `ios-h18p` | h18p | iPhone 17 Pro |

Each folder is a complete bundle: `metadata.json` (pointing at the compiled model),
`tokenizer/`, and `minicpm5_1b_minicpm5_pal8_g32_static.<arch>.aimodelc`. A phone
needs only the folder whose architecture matches `AIModel.deviceArchitectureName`.
Other devices should use the portable model below and let Core AI compile it.

## Source and build

- Model: [openbmb/MiniCPM5-1B](https://huggingface.co/openbmb/MiniCPM5-1B), 8-bit
  palettized, 4,096-token context.
- Portable Core AI export: [mlboydaisuke/MiniCPM5-1B-CoreAI](https://huggingface.co/mlboydaisuke/MiniCPM5-1B-CoreAI)
  `ios-static/` at revision `f38d143ec50cb2e54d8388479b919e3b9283943b`.
- Compiled on GitHub Actions (Xcode 27, Metal Toolchain) by
  [`compile-models.yml`](https://github.com/array-ai/fieldnotes/blob/main/.github/workflows/compile-models.yml):

```
xcrun coreai-build compile minicpm5_1b_minicpm5_pal8_g32_static.aimodel \
  --platform iOS --min-deployment-version 27.0 --architecture <arch> --output <dir>
```

Compute units were left to Core AI's default choice. Some on-device specialization
still happens at first load, but not the full compile.

## Loading

```swift
import CoreAI
import CoreAILanguageModels

let arch = AIModel.deviceArchitectureName           // e.g. "h17g"
let bundle = modelsDirectory.appending(path: "ios-\(arch)")
let model = try await CoreAILanguageModel(resourcesAt: bundle)
```

Fieldnote downloads only the matching folder, from a pinned revision of this repo,
and checks every file against its SHA-256 before use.

## Licence

MiniCPM5 is released by OpenBMB under the Apache License 2.0, and so are these
compiled bundles (see `LICENSE`). No weights were changed; the files here are the
portable export compiled for specific chips.
