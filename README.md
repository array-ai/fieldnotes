# Fieldnote

A meeting recorder for iPhone that transcribes, works out who spoke when, and
summarises, all on the device. No server, no account, and no network access unless
you turn on Apple Maps place names.

> **Experimental.** Fieldnote runs on a real iPhone, but it still has small bugs.
> Expect rough edges.
>
> **Written almost entirely by AI** (Claude), directed and reviewed by publicarray.

## What it does

- **Records** with a Live Activity on the lock screen. Audio is written to disk in
  chunks as it goes, so a crash or a kill loses seconds, not the meeting.
- **Transcribes** live with Apple's `SpeechAnalyzer`, then re-transcribes from the
  saved audio if the live pass missed anything.
- **Identifies speakers** with one of three on-device models, chosen in Settings:

  | Method | What it is |
  |---|---|
  | **Nemotron 3** (default) | NVIDIA's end-to-end diarizer. Handles overlapping speech, up to 8 speakers |
  | **pyannote community-1** | Segmentation, speaker embeddings, then clustering over the whole recording |
  | **pyannote 3.1 (legacy)** | The original pipeline, kept for comparison |

  With Nemotron 3, speakers can be identified while you record (on by default), so
  they're ready the moment you stop. Unnamed speakers show as Speaker A, Speaker B and
  so on. Picks up names from
  self-introductions ("Hi, I'm Priya") and lets you rename speakers by hand.
- **Summarises** into notes with Apple's on-device Foundation Models: an overview,
  topic sections (headline, one-line summary, timestamped key points with supporting
  details), action items grouped by owner, decisions and open questions. The meeting
  list shows each meeting's top topics at a glance. Every point cites the transcript lines it came
  from, and a point whose citation doesn't check out is dropped. Long transcripts are
  sized against the model's measured context and split where needed.
- **Imports** recordings made elsewhere (Voice Memos, a dictaphone, audio downloaded
  from a meeting service such as Fireflies): use Import in the meeting list, or
  "Open in Fieldnote" from another app's share sheet. Imported audio is transcribed,
  split by speaker and summarised like a recording made in the app.
- **Exports** through the share sheet as Markdown, plain text, PDF, SRT/VTT subtitles
  or audio, sends tasks to Reminders, and makes encrypted backups.
- **Keeps working in the background** after you press stop. Processing runs as a
  continued-processing task and resumes from its last checkpoint if iOS kills it.

- **Debug mode** (Settings) adds an activity log of what ran, for how long and what
  failed, and Redo actions on each meeting for the transcript, speakers or summary.
  The log records timings and errors only, never what was said.

Meetings can be renamed at any time from the meeting screen.

## Privacy

This is the point of the app, and it is enforced by tests rather than by intention:

- **No networking code.** The app contains no `URLSession` or similar, and requests no
  network entitlement.
- **No cloud models.** Every language-model session is pinned to the on-device model.
- **No model downloads.** The speech-model files ship inside the app. The libraries'
  download-on-first-use loaders are banned in the source.
- **No Siri or Spotlight indexing.** There are no App Intents, so meeting content never
  reaches the system's semantic index.
- **Location is opt-in.** The place is named offline (nearest suburb or town, from a
  table built into the app). A business or building name needs Apple Maps, which is
  a separate setting, off by default, that sends only the coordinates to Apple. All
  Apple Maps calls live in one file, and a policy check keeps them there.

Meeting content leaves the phone only when you share it yourself.

The one third-party library is [FluidAudio](https://github.com/FluidInference/FluidAudio),
which runs the speaker-identification models with CoreML. No analytics or networking
SDKs are included.

## Status

| | |
|---|---|
| Core logic (`Core/`) | Builds and tests on Linux, no Apple SDK. 97 tests, run in CI on every push |
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

The speaker-identification models aren't in git (about 132 MB). Fetch them from pinned
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

Dependencies keep their own licences: FluidAudio is Apache-2.0, the bundled models are
CC-BY-4.0 (pyannote) and OpenMDW-1.1 (Nemotron 3), and the offline place names come
from [GeoNames](https://www.geonames.org) (CC-BY 4.0).
