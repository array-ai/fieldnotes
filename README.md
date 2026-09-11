# Fieldnote

On-device meeting recorder, transcriber, diarizer and summariser for iOS 27 / macOS 27.
Built for MSP field work: in-person site visits, scoping calls, incident reviews.

Everything stays on the device. There is no Fieldnote server, no account, no
subscription, and no third-party SDK. Content leaves only when the user drives the
system share sheet themselves.

---

## Status

**v1 scaffold, not yet compiled.** Every file here was written on Linux, where there
is no Swift toolchain, no Xcode and no Apple SDK. So:

- the pure logic (alignment, chunking, grounding, date resolution, export formats,
  checkpoint bookkeeping) is complete and covered by unit tests;
- the framework-facing code (Speech, Foundation Models, FluidAudio, BackgroundTasks,
  ActivityKit, SwiftData) is complete in shape but **has never been through a
  compiler**. Expect a first-build pass of signature fixes;
- everything the SDK might spell differently is isolated behind a marked adapter, so
  those fixes are one-line and local rather than a hunt. See
  [API surface to verify](#api-surface-to-verify).

The policy checks in `Scripts/policy-check.sh` do run, here and in CI, and they pass.

## Build

Requires macOS 27, Xcode 27, and a physical iPhone 15 Pro / iPhone 16 or later. The
Speech live-audio path does not run in Simulator, and the Apple Intelligence stack is
not present on older hardware.

```sh
brew install xcodegen
./Scripts/generate-project.sh     # writes Fieldnote.xcodeproj from project.yml
open Fieldnote.xcodeproj
```

Before first run, vendor the diarization models into the bundle — Fieldnote will not
download them (see [Decisions](docs/decisions.md#diarization-models-are-vendored-not-downloaded)):

```sh
./Scripts/vendor-diarization-models.sh ~/Downloads/fluidaudio-models
```

## The rules, and how they are held

These are not style preferences. Each one is a way client meeting audio could leave
the device, and each is enforced by something that fails a build rather than by
someone remembering.

| Rule | Enforced by |
|---|---|
| Every Foundation Models session is pinned to the on-device model | `PolicyTests.sessionsOnlyFromFactory` + `policy-check.sh`. `OnDeviceModel` is the only file allowed to construct a session |
| No third-party `LanguageModel` provider (Claude, Gemini, anything conforming) | `PolicyTests.noThirdPartyProviders` + CI grep |
| No App Intents at all; nothing in the Spotlight semantic index | `PolicyTests.noAppIntents` + CI grep |
| No networking code anywhere in the app | `PolicyTests.noNetworking` + CI grep; no network entitlements in `Fieldnote.entitlements` |
| Background inference entitlement present | `PolicyTests.inferenceEntitlement` |

**Fieldnote is invisible to Siri's content search, deliberately.** iOS 27 rebuilt Siri
on a cloud Gemini model, and App Intents 2.0 contributes app content to the Spotlight
semantic index so Siri can answer questions about it. For most apps that is a
discovery win. For an app holding client meeting transcripts it is a data-exfiltration
path with a friendly name. Do not "fix" this later.

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

| Area | Files |
|---|---|
| Capture | `Fieldnote/Audio/` — engine, chunked writer, diarization buffer, session interruptions, Live Activity |
| Transcription | `Fieldnote/Transcription/` — asset provisioning, live session, file-based recovery path, MSP vocabulary |
| Diarization | `Fieldnote/Diarization/` — FluidAudio wrapper, overlap-based alignment |
| Summarisation | `Fieldnote/Summarisation/` — on-device pin, chunker, prompts, grounding, templates |
| Pipeline | `Fieldnote/Pipeline/` — checkpoints, three-stage run, background coordinator |
| Data | `Fieldnote/Data/` — SwiftData models, store, storage locations |
| Export | `Fieldnote/Export/` — Markdown, plain text, PDF, WebVTT/SRT, audio join, Reminders, encrypted backup |
| UI | `Fieldnote/UI/` — list, recorder, detail, share, settings |

Two design points worth knowing before reading the code:

**The model never emits UUIDs.** The prompt numbers the transcript lines it is given,
the model cites line numbers, and `SummaryGrounder` maps them back to segment IDs —
discarding any claim whose citation does not resolve. An unresolvable citation is
worse than none, because it looks like grounding.

**Every stage checkpoints before the next one starts.** The system kills
continued-processing tasks under pressure, prioritising those reporting little
progress, and long tasks expire unpredictably in production. A killed run resumes at
its last completed stage, never from raw audio.

## Testing

```sh
./Scripts/policy-check.sh                    # runs anywhere, including Linux
xcodebuild test -scheme Fieldnote -destination 'platform=iOS,name=<your device>'
```

The unit suites cover speaker alignment, chunking, grounding, relative dates, export
formats, checkpoint bookkeeping and backup encryption. What they cannot cover, and
what has to be checked by hand on a device:

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
| `AnalysisContext.contextualStrings` | `TranscriptionSession.applyContextualStrings` | Measure its effect on the long-form path, then keep or drop it (spec 4.3) |
| FluidAudio model loading | `DiarizationModelProvider` | Pinned package version in `project.yml` |
| `BGContinuedProcessingTask` submission | `BackgroundProcessingCoordinator.submit` | Handles a false `supportedResources.contains(.gpu)` rather than assuming broken provisioning |

## Deliberately not here

v1 is six things: capture, transcribe, diarize, summarise, survive backgrounding, hand
off. Everything else was specified and cut, and is recorded in
[docs/decisions.md](docs/decisions.md) and section 11 of the build spec:

- persistent speaker identity across meetings (embeddings are stored from day one so
  it can be built against real history);
- terminology correction;
- consent logging, the consent badge and the share gate;
- speaker analytics and cross-meeting profiles;
- the Evaluations harness;
- HaloPSA and Hudu integrations.

## Licence

MIT, if this is ever made public. A no-network, no-account, share-sheet-only notetaker
is an underserved niche, and the absence of integrations is the selling point.
