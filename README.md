# Fieldnote

On-device meeting recorder, transcriber, diarizer and summariser for iOS 27.
Built for MSP field work: in-person site visits, scoping calls, incident reviews.

Everything stays on the device. There is no Fieldnote server, no account, no
subscription, and no third-party SDK. Content leaves only when the user drives the
system share sheet themselves.

Built with [xtool](https://xtool.sh), not Xcode: SwiftPM on Linux, signed and
installed straight to a device.

---

## Status

**Compiles against the iOS 27 SDK.** The app and the widget extension build clean for
`arm64-apple-ios27.0` on Xcode 27 in CI, and the Core suites pass on Linux. Nothing
here has run on a device yet — building is not working, and every runtime claim in
this README is still unverified. What that means concretely:

- `Core/` — alignment, chunking, grounding, relative dates, export formats, checkpoint
  bookkeeping — is written to build and test on a plain Linux toolchain with no Apple
  SDK, and CI runs `swift test --package-path Core` on every push. Run it locally and
  it will tell you the truth; nobody has been able to yet.
- `Sources/Fieldnote` and `Sources/FieldnoteWidgets` compile, which is not the same as
  work. The pipeline has never processed a real recording; the device checks under
  [Testing](#testing) are what would make any of it trustworthy.
- Both toolchains build it: `Scripts/xtool.sh dev build` packs an unsigned `.app`,
  and the generated Xcode workspace builds with `xcodebuild`. CI runs both.

`Scripts/policy-check.sh` does run here, and passes. It is pure grep, so it gates every
push regardless of toolchain.

## Build

### Prerequisites

Per [xtool's Linux install guide](https://xtool.sh/documentation/xtooldocs/installation-linux):

- **A Swift toolchain that matches the SDK** — see below. As of writing that means a
  Swift **6.4** snapshot, not the 6.3.3 stable release.
- **usbmuxd** — `sudo apt-get install usbmuxd libimobiledevice-utils`
- **xtool** — the `xtool.AppImage` from the latest GitHub release, on your `PATH`
- **An Xcode xip**, which `xtool setup` unpacks into a Darwin Swift SDK. Use the
  **Xcode 27** xip: the xtool docs say Xcode 26, but this project deploys to iOS 27
  and needs that SDK for AFM 3, `BGContinuedProcessingTask` inference and
  `CaptureInputSequenceProvider`.
- **An iPhone 15 Pro / iPhone 16 or later.** The floor is Apple Intelligence hardware,
  not iOS 27, and the app refuses at launch on anything below it.

### Toolchain and SDK must match

The Darwin SDK is generated from an Xcode xip, and it carries that Xcode's Swift
module interfaces. The host toolchain has to be at least that version, or every build
fails before it reaches your code:

```
error: failed to build module 'Swift'; this SDK is not supported by the compiler
(the SDK is built with 'Apple Swift version 6.4 ...', while this compiler is
'Swift version 6.3.3 (swift-6.3.3-RELEASE)')
```

Xcode 27 ships Swift 6.4, and Swift 6.4 is not GA for Linux yet, so the pairing today
is an Xcode 27 SDK plus a 6.4 snapshot:

```sh
swiftly list-available | grep 6.4      # find the current 6.4 snapshot tag
swiftly install 6.4.x-snapshot
swiftly use 6.4.x-snapshot
swift --version                        # must report 6.4, not 6.3.x
```

xtool's own docs say Swift 6.3, which is correct for an Xcode 26 SDK — but an Xcode 26
SDK cannot build this project, because the deployment target is iOS 27. The versions
move together: newer Xcode xip, newer host toolchain.

If a 6.4 snapshot is not usable on your machine, the Mac path still works — the
project builds with Xcode as well (see below) — and `swift test --package-path Core`
is unaffected either way, since Core needs no Apple SDK.

### First run

```sh
xtool setup                                   # Apple ID + Darwin SDK, once
Scripts/vendor-diarization-models.sh ~/Downloads/fluidaudio-models  # layout: Resources/README.md
swift test --package-path Core                # cross-platform half, no device needed
./Scripts/xtool.sh dev run                    # build, sign, install, launch
```

### Xcode

The same package builds in Xcode — one manifest, two toolchains, no second project to
keep in sync:

```sh
./Scripts/generate-xcode-project.sh
open xtool/Fieldnote.xcworkspace
```

The workspace is generated from `Package.swift` and `xtool.yml` and is gitignored.
Edit the manifests, not the project.

### Why `Scripts/xtool.sh` rather than `xtool` directly

xtool's packer copies products out of `.build/<triple>/<config>` — SwiftPM's *native*
build-system layout. Swift 6.4 (Xcode 27) defaults to the `swiftbuild` system, which
writes to `.build/out/Products/...`, so a clean compile is followed by the packer
failing on a missing resource bundle. xtool exposes no flag for build options, but it
honours `SWIFTPM_CUSTOM_BIN_DIR`, so the wrapper points that at shims that add
`--build-system native`. Drop the wrapper when xtool learns the newer layout — nothing
in the app depends on it.

### Signing caveat worth knowing before you start

`Config/Fieldnote.entitlements` requests
`com.apple.developer.background-tasks.continued-processing.inference`. A free personal
team cannot sign that entitlement, and a paid team needs the capability enabled on the
App ID. If signing refuses it, the pipeline still runs — `BackgroundProcessingCoordinator`
falls back to in-process work and the checkpoints make the next launch resume — but
processing will not survive the app being backgrounded, which is the whole point of
that stage. Fix the provisioning rather than living with it.

## The rules, and how they are held

These are not style preferences. Each one is a way client meeting audio could leave the
device, and each is enforced by something that fails a build rather than by someone
remembering.

| Rule | Enforced by |
|---|---|
| Every Foundation Models session is pinned to the on-device model | `PolicyTests.sessionsOnlyFromFactory` + `policy-check.sh`. `OnDeviceModel` is the only file allowed to construct a session |
| No third-party `LanguageModel` provider (Claude, Gemini, anything conforming) | `PolicyTests.noThirdPartyProviders` + CI grep |
| No App Intents at all; nothing in the Spotlight semantic index | `PolicyTests.noAppIntents` + CI grep |
| No networking code anywhere in the app | `PolicyTests.noNetworking` + CI grep; no network entitlements in `Config/Fieldnote.entitlements` |
| Background inference entitlement present | `PolicyTests.inferenceEntitlement` |

**Fieldnote is invisible to Siri's content search, deliberately.** iOS 27 rebuilt Siri
on a cloud Gemini model, and App Intents 2.0 contributes app content to the Spotlight
semantic index so Siri can answer questions about it. For most apps that is a discovery
win. For an app holding client meeting transcripts it is a data-exfiltration path with
a friendly name. Do not "fix" this later.

## Architecture

```
mic ──┬── TranscriptionSession (SpeechAnalyzer)  → live transcript
      ├── ChunkedAudioWriter                     → m4a chunks on disk, continuously
      └── DiarizationBuffer (16 kHz mono Float32) → one batch pass on stop
                                    │
                            stop pressed
                                    │
                    BGContinuedProcessingTask (inference entitlement)
                                    │
        transcribe ──► diarize ──► summarise      each stage checkpointed to disk
                                    │
                              share sheet
```

### Layout

```
Package.swift            app + widget, built by xtool
xtool.yml                bundle ID, Info.plist paths, entitlements, extensions
Config/                  Info.plists and entitlements (no Xcode build settings in them)
Resources/               copied into the bundle; vendored CoreML models live here
Core/                    FieldnoteCore package: cross-platform, Linux-testable
Sources/Fieldnote/       the app: Apple frameworks live here
Sources/FieldnoteShared/ types the app and the widget share (ActivityKit attributes)
Sources/FieldnoteWidgets/ Live Activity extension
Tests/FieldnoteTests/    Darwin-only tests (CryptoKit); Core holds the rest
```

| Area | Files |
|---|---|
| Capture | `Sources/Fieldnote/Audio/` — engine, chunked writer, diarization buffer, interruptions, Live Activity |
| Transcription | `Sources/Fieldnote/Transcription/` — asset provisioning, live session, file-based recovery, MSP vocabulary |
| Diarization | `Sources/Fieldnote/Diarization/` — FluidAudio wrapper; alignment is in Core |
| Summarisation | `Sources/Fieldnote/Summarisation/` — on-device pin, drafts, context budget; prompts, chunking and grounding are in Core |
| Pipeline | `Sources/Fieldnote/Pipeline/` — checkpoint store, three-stage run, background coordinator |
| Data | `Sources/Fieldnote/Data/` — SwiftData models, store, storage locations |
| Export | `Sources/Fieldnote/Export/` — PDF, audio join, Reminders, encrypted backup; Markdown, plain text and subtitles are in Core |
| UI | `Sources/Fieldnote/UI/` |

Two design points worth knowing before reading the code:

**The model never emits UUIDs.** The prompt numbers the transcript lines it is given,
the model cites line numbers, and `SummaryGrounder` maps them back to segment IDs —
discarding any claim whose citation does not resolve. An unresolvable citation is worse
than none, because it looks like grounding. The grounder takes plain `ChunkNotes`
values rather than `@Generable` drafts, which is what lets it be tested on Linux.

**Every stage checkpoints before the next one starts.** The system kills
continued-processing tasks under pressure, prioritising those reporting little
progress, and long tasks expire unpredictably in production. A killed run resumes at
its last completed stage, never from raw audio.

## Testing

```sh
./Scripts/policy-check.sh          # anywhere, no toolchain needed
swift test --package-path Core     # Linux, no Apple SDK, no device
```

What those cannot cover, and what has to be checked by hand on a device:

- Airplane Mode end to end: record 10 minutes, stop, get a speaker-labelled transcript
  and a summary.
- Proxy capture over a normal recording: zero outbound requests of any kind.
- 90 minutes, backgrounded on stop, phone locked and pocketed for the whole run.
- Forced app kill mid-recording, and again mid-pipeline: the second must resume from a
  checkpoint, not restart.
- Prompt changes: re-run a fixed set of 6-8 real recordings and read the output
  yourself. Prompt edits are code changes with no compiler. Apple's Evaluations
  framework automates this and is v2 work; its absence is not a licence to skip it.

## API surface to verify

Written against the spec's description of the iOS 27 SDKs. Each is isolated so a
signature change is a one-line fix:

| What | Where | If it differs |
|---|---|---|
| On-device tier selection and the pin | `OnDeviceModel.pinnedModel(for:)` | Fix here only. Both tiers currently resolve to the on-device default; Core Advanced gets its own selector when confirmed |
| Context size and token counting | `ContextBudget.measure` | Returns the documented fallback until wired; `isMeasured` records which path ran |
| `AnalysisContext.contextualStrings` | `TranscriptionSession.applyContextualStrings` | Measure its effect on the long-form path, then keep or drop it |
| FluidAudio model loading | `DiarizationModelProvider` | Pinned package version in `Package.swift` |
| `BGContinuedProcessingTask` submission | `BackgroundProcessingCoordinator.submit` | Handles a false `supportedResources.contains(.gpu)` rather than assuming broken provisioning |

### Deprecated on iOS 27, still building

The Xcode 27 compiler flags three APIs this code uses. They work, so they are not
blocking, but they are the next thing to modernise — and the first one changes how
interruption handling should be written, which is spec 4.1 territory:

| Deprecated | Replacement the compiler names | Used in |
|---|---|---|
| `AVAudioSession.InterruptionType` | `AVAudioSessionDidBecomeInactiveNotification` + `AVAudioSessionResumptionRecommendationNotification` | `AudioSessionController` |
| `AVAudioSession.InterruptionOptions` | `AVAudioSessionResumptionRecommendationNotification` | `AudioSessionController` |
| `installTap(onBus:bufferSize:format:block:)` | (not named in the diagnostic) | `RecordingController` |

## Deliberately not here

v1 is six things: capture, transcribe, diarize, summarise, survive backgrounding, hand
off. Everything else was specified and cut, and is recorded in
[docs/decisions.md](docs/decisions.md) and section 11 of the build spec:

- persistent speaker identity across meetings (embeddings are stored from day one so it
  can be built against real history);
- terminology correction;
- consent logging, the consent badge and the share gate;
- speaker analytics and cross-meeting profiles;
- the Evaluations harness;
- HaloPSA and Hudu integrations.

The macOS target in the spec is also parked: xtool builds iOS only. The `#if os(macOS)`
branches in the code are kept but unbuilt, so they are stale until someone opens the
package in Xcode on a Mac and fixes them.

## Licence

MIT, if this is ever made public. A no-network, no-account, share-sheet-only notetaker
is an underserved niche, and the absence of integrations is the selling point.
