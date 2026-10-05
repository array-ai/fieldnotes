# Fieldnote

A meeting recorder for iPhone that transcribes, works out who spoke when, and
summarises, all on the device. No server, no account, and no network access except
two things you choose: optional model downloads, and Apple Maps place names.

> **Experimental.** Fieldnote runs on a real iPhone, but it still has small bugs.
> Expect rough edges.
>
> **Written almost entirely by AI** (Claude), directed and reviewed by publicarray.

## What it does

- **Records** with a Live Activity on the lock screen. Audio is written to disk in
  chunks as it goes, so a crash or a kill loses seconds, not the meeting.
- **Transcribes** live with Apple's `SpeechAnalyzer`. Optionally, one of NVIDIA's
  Parakeet models rewrites the transcript after you stop, for better accuracy:
  TDT v3 (483 MB, 25 European languages), TDT v2 English (464 MB, the most accurate
  for English) or TDT-CTC 110M English (228 MB, smaller and quicker). Settings shows
  each model as a card with relative accuracy and speed, so the choice is easy.
- **Identifies speakers** on device, chosen in Settings:

  | Method | What it is | |
  |---|---|---|
  | **Nemotron 3** (default) | NVIDIA's end-to-end diarizer. Handles overlapping speech, up to 8 speakers | built in |
  | **pyannote community-1** | Segmentation, speaker embeddings, then clustering over the whole recording | 22 MB download |
  | **pyannote 3.1 (legacy)** | The original pipeline, kept for comparison | 14 MB download |

  With Nemotron 3, speakers can be identified while you record (on by default), so
  they're ready the moment you stop. Speakers are assigned word by word (each word goes
  to whoever was talking at its midpoint), so a line where two people talk is split
  between them. Unnamed speakers show as Speaker A, Speaker B and
  so on. Picks up names from
  self-introductions ("Hi, I'm Priya") and lets you rename speakers by hand.
- **Summarises** into notes on the phone, with Apple's on-device Foundation Models
  model or, optionally, Qwen3 1.7B (a 1.4 GB download, run through Apple's Core AI
  runtime: twice the context and no false content refusals): an overview,
  topic sections (headline, one-line summary, timestamped key points with supporting
  details), action items grouped by owner, decisions and open questions. The meeting
  list shows each meeting's top topics at a glance. Every point cites the transcript lines it came
  from, and a point whose citation doesn't check out is dropped. Long transcripts are
  sized against the model's measured context and split where needed.
- **Imports** recordings made elsewhere (Voice Memos, a dictaphone, audio downloaded
  from a meeting service such as Fireflies): use Import in the meeting list, or
  "Open in Fieldnote" from another app's share sheet. Imported audio is transcribed,
  split by speaker and summarised like a recording made in the app.
- **Plays back** the recording above the transcript, with the line being spoken
  highlighted and kept in view. Tap a line, or a timestamp in the summary, to play
  from there.
- **Exports** through the share sheet as Markdown, plain text, PDF, SRT/VTT subtitles
  or audio, sends tasks to Reminders, and makes encrypted backups.
- **Keeps working in the background** after you press stop: the transcript and
  speakers finish in a continued-processing task, resuming from a checkpoint if iOS
  stops it. The notes are written while the app is open, because Apple's on-device
  model rate-limits background requests; if you've left, a notification says the
  notes will finish when you come back. It shows how long is left (learned from this
  phone's past runs) and notifies you when the notes are ready.

- **Debug mode** (Settings) adds an activity log of what ran, for how long and what
  failed, Redo actions on each meeting for the transcript, speakers or summary, a
  benchmark that times every on-device model on one of your recordings, and an
  editor for the summary prompt (the grounding rules stay attached).
  The log records timings and errors only, never what was said.

Meetings can be renamed at any time from the meeting screen.

## Privacy

This is the point of the app, and it is enforced by tests rather than by intention:

- **No network use you didn't ask for.** Two things can go online, both only when you
  choose them, and each confined to one file by a policy check:
  - **Optional models** (Settings → Models) download from Hugging Face when you tap
    Download: pinned to a fixed version, every file checked against its SHA-256.
  - **Apple Maps place names** (below).
- **No cloud models.** Every model runs on the phone. Every language-model session is
  pinned to Apple's on-device model, and the speech libraries' download-on-first-use
  loaders are banned in the source.
- **No Siri or Spotlight indexing.** There are no App Intents, so meeting content never
  reaches the system's semantic index.
- **Location is opt-in.** The place is named offline (nearest suburb or town, from a
  table built into the app). A business or building name needs Apple Maps, which is
  a separate setting, off by default, that sends only the coordinates to Apple. All
  Apple Maps calls live in one file, and a policy check keeps them there.

Meeting content leaves the phone only when you share it yourself.

The one third-party library is [FluidAudio](https://github.com/FluidInference/FluidAudio),
which runs the speaker and Parakeet models with CoreML. No analytics or networking
SDKs are included.

## Status

| | |
|---|---|
| Core logic (`Core/`) | Builds and tests on Linux, no Apple SDK. 129 tests, run in CI on every push |
| App and widget | Build for `arm64-apple-ios27.0` in CI with Xcode 27, both through xtool and `xcodebuild` |
| On a device | Runs on iPhone, with known small bugs. The device checks under [Testing](#testing) haven't all been done |
| Linux device builds | Blocked: the bundled LLD can't read the iOS 27 SDK's stubs (see [Build](#build)) |

## Requirements

- An **iPhone 15 Pro, iPhone 16 or later** on **iOS 27**. The app needs Apple
  Intelligence hardware and refuses to run without it.
- **Xcode 27**, or [xtool](https://xtool.sh) on Linux with an Xcode 27 SDK.
- An Apple developer team. See [Signing](#signing).

## Build

### Get the models

The bundled speaker model (Nemotron 3) isn't in git (about 98 MB). Fetch it from pinned
Hugging Face revisions and copy them into `Resources/DiarizationModels`:

```sh
Scripts/fetch-diarization-models.sh /tmp/fieldnote-models
Scripts/vendor-diarization-models.sh /tmp/fieldnote-models
```

[Resources/README.md](Resources/README.md) lists every file, its source and its licence.

### On a Mac

```sh
./Scripts/generate-xcode-project.sh
open xtool/Fieldnote.xcworkspace
```

The workspace is generated from `Package.swift` and `xtool.yml` and is gitignored, so
edit those, not the project.

### On Linux, with xtool

```sh
xtool setup                       # Apple ID and Darwin SDK, once
./Scripts/xtool.sh dev run        # build, sign, install, launch
```

Use `Scripts/xtool.sh`, not plain `xtool`. Swift 6.4 builds into a different directory
layout than xtool's packer expects, and the wrapper forces the older one.

Two version traps:

- **The toolchain must match the SDK.** An Xcode 27 SDK carries Swift 6.4 module
  interfaces, so the host needs a Swift 6.4 toolchain, which on Linux means a snapshot
  (`swiftly install 6.4.x-snapshot`). xtool's docs say Swift 6.3 and Xcode 26, but an
  iOS 26 SDK can't build an iOS 27 target.
- **Linking currently fails.** The iOS 27 SDK's `.tbd` stubs list an `arm64e.x1-ios`
  architecture that the LLD 21 in current Swift 6.4 snapshots rejects
  (`unknown architecture`). Until a toolchain ships a newer LLD, build on a Mac or in CI.

### Signing

The app requests the
`com.apple.developer.background-tasks.continued-processing.inference` entitlement. A
free personal team can't sign it, and a paid team has to enable it on the App ID.
Without it the app still works, but processing stops when the app goes to the
background.

`Scripts/sign-and-upload.sh` and `.github/workflows/release.yml` sign and upload to
TestFlight from CI, using App Store Connect secrets.

## Testing

```sh
./Scripts/policy-check.sh          # the privacy rules, plain grep, runs anywhere
swift test --package-path Core     # Linux or Mac, no device
```

| Rule | Checked by |
|---|---|
| Model sessions only built in `OnDeviceModel`, pinned on-device | `PolicyTests.sessionsOnlyFromFactory`, `policy-check.sh` |
| No third-party `LanguageModel` providers | `PolicyTests.noThirdPartyProviders` |
| No App Intents or semantic indexing | `PolicyTests.noAppIntents` |
| No networking code, no network entitlements | `PolicyTests.noNetworking`, `noNetworkEntitlements` |
| Apple Maps place lookups only in `PlaceNamer` | `PolicyTests.placeLookupsConfined` |
| Model downloads only in `ModelDownloads` | `PolicyTests.downloadsConfined` |
| Local summary model built only in `OnDeviceModel`; no cloud model or downloading tokenizer | `PolicyTests.localModelConfined` |
| No download-on-first-use model loaders | `PolicyTests.noModelDownloads` |
| Background inference entitlement present | `PolicyTests.inferenceEntitlement` |

These checks can't cover the following, which needs a device:

- Airplane Mode, end to end: record 10 minutes, stop, get a labelled transcript and a
  summary.
- A proxy capture during a normal recording shows zero outbound requests.
- A 90-minute recording, backgrounded on stop with the phone locked.
- Killing the app mid-recording and mid-processing: processing must resume from a
  checkpoint, not restart.
- Comparing the three speaker-identification methods on the same recordings.
- After any prompt change, re-reading the output for a fixed set of real recordings.

## Benchmarks

Measured on an iPhone 16 (iPhone17,3, 8 GB, iOS 27.0.1) with the app in front. Run
your own from Settings → Debug → Benchmark.

| Stage | Model | Audio | Time | × real time |
|---|---|---|---|---|
| Speakers | Nemotron 3, Neural Engine | 5 min / 68 min | 0.73 s / 33 s | 410× / 124× |
| Speakers | Nemotron 3, CPU fallback | 5 min | 2.15 s | 140× |
| Speakers | pyannote community-1 | 5 min | 1.39 s | 215× |
| Speakers | pyannote 3.1 (legacy) | 5 min | 3.42 s | 88× |
| Transcript | Parakeet TDT-CTC 110M | 18.6 min / 68 min | 5.0 s / 48.8 s | 224× / 84× |
| Transcript | Apple speech, from the audio files | 18.6 min | 80 s | 14× |
| Summary | Apple's on-device model | 18.6 min | 290 s | 27–40 tokens/s |

- Nemotron's Neural Engine model compiles once per install (23–40 s). The CPU model covers that first run.
- Apple's language model ran at about 10 tokens/s in one long run, three to four times slower; likely a hot or locked phone. In background tasks on battery it is rate-limited.
- Parakeet v3, v2 English and Qwen3 1.7B are not measured yet.
- Processing-time estimates start from these numbers and then learn this phone's speed for each model.

## How it works

```
mic ──┬── TranscriptionSession (SpeechAnalyzer)   → live transcript
      ├── ChunkedAudioWriter                      → m4a chunks on disk
      └── DiarizationBuffer (16 kHz mono Float32) → one pass on stop
                                │
                          stop pressed
                                │
                BGContinuedProcessingTask (inference entitlement)
                                │
        transcribe ──► diarize ──► summarise      each stage checkpointed
                                │
                           share sheet
```

Two design choices worth knowing before reading the code:

- **The model never emits IDs.** The prompt numbers the transcript lines, the model
  cites line numbers, and `SummaryGrounder` maps them back to segments. A citation that
  doesn't resolve drops its claim, because a wrong citation looks like evidence.
- **Every stage checkpoints before the next starts.** iOS kills long background tasks
  unpredictably. A killed run resumes at its last finished stage, never from raw audio.

### Layout

```
Core/                     cross-platform logic, Linux-testable: alignment, chunking,
                          grounding, prompts, exports, dates
Sources/Fieldnote/        the app: audio, transcription, diarization, summarisation,
                          pipeline, SwiftData store, exports, UI
Sources/FieldnoteShared/  types shared with the widget
Sources/FieldnoteWidgets/ Live Activity extension
Tests/FieldnoteTests/     Darwin-only tests (CryptoKit)
Config/                   Info.plists and entitlements
Resources/                bundled into the app; the CoreML models go here
Scripts/                  build, model, policy and release scripts
docs/decisions.md         where the build departs from the original spec, and why
```

### Unverified iOS 27 APIs

Parts of this were written against descriptions of the iOS 27 SDK rather than tested
behaviour. Each is isolated so a change is a one-place fix:

| What | Where |
|---|---|
| On-device model tier selection | `OnDeviceModel.pinnedModel(for:)` |
| `AnalysisContext.contextualStrings` | `TranscriptionSession.applyContextualStrings` |
| `BGContinuedProcessingTask` submission | `BackgroundProcessingCoordinator.submit` |

The audio interruption APIs in `AudioSessionController` and `installTap` in
`RecordingController` are deprecated in iOS 27 and due to be replaced.

## Not in v1

Left out on purpose; reasons are in [docs/decisions.md](docs/decisions.md):

- recognising the same person across meetings (speaker embeddings are stored now, so
  this can be built later);
- terminology correction;
- consent logging;
- speaker analytics;
- an automated evaluation harness for prompts;
- integrations with other tools;
- a macOS app (the `#if os(macOS)` branches exist but are unbuilt and stale).

## Licence

[0BSD](LICENSE): use it for anything, no attribution required, no warranty. The code
was written almost entirely by AI, so a public-domain-style licence is the honest fit.

Dependencies keep their own licences: FluidAudio is Apache-2.0, Apple's coreai-models
is BSD-3-Clause (its swift-transformers and xgrammar dependencies are Apache-2.0; the
download code in swift-transformers is never called — the policy checks ban it in the
app's sources), Qwen3 is Apache-2.0, Nemotron 3 is
OpenMDW-1.1, the optional pyannote and Parakeet models are CC-BY-4.0, and the offline place names come
from [GeoNames](https://www.geonames.org) (CC-BY 4.0).
