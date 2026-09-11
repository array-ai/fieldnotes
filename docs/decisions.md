# Decisions

Where the build deviates from the spec, where the spec's own constraints collide, and
where a judgement call was made that the next person should be able to overturn on
purpose rather than by accident.

---

## Built with xtool, and split into two packages because of it

**What changed.** The project was scaffolded for Xcode (XcodeGen + a `project.yml`).
It now builds with [xtool](https://xtool.sh): SwiftPM on Linux, signed and installed
to a device without a Mac. `project.yml` and the generator script are gone — on a Mac,
`xtool dev generate-xcode-project` produces a project from the same package.

**What xtool imposes.** The app must be a SwiftPM *library* product, and so must each
extension; the rest (bundle ID, Info.plist path, entitlements, extensions) lives in
`xtool.yml`. Info.plists are merged over xtool's defaults, so `$(PRODUCT_NAME)` style
build settings had to come out of them: nothing substitutes those outside Xcode.

**The split.** The codebase is now two packages:

- `Core/` (`FieldnoteCore`, product `FieldnoteKit`) — no AVFoundation, no Speech, no
  FoundationModels, no SwiftData, no CoreGraphics. Builds and tests on a plain Linux
  toolchain.
- the root package — the app, the widget, and everything that needs an Apple SDK.

Two packages rather than two targets in one, because `swift test` builds every test
target in a package: with one package, running the Core tests on Linux would drag the
iOS-only targets into the build and fail. `swift test --package-path Core` sidesteps
that cleanly.

**What this buys.** The parts where a bug is silent — a speaker label off by one span,
a citation resolving to the wrong line, a chunk boundary eating a decision — are now
compiled and tested on every push, with no Mac, no device and no Apple SDK. That is
most of the reasoning in this codebase.

**What it costs.** `ChunkNotes` in FieldnoteKit mirrors the `@Generable` draft types in
the app, because `@Generable` only exists where FoundationModels does. The app converts
drafts into notes in a dozen lines at the bottom of `DraftTypes.swift`. That mirroring
is the price of testing grounding without a device, and grounding is the single thing
most worth testing.

**Still Apple-shaped.** xtool replaces Xcode, not Apple: `xtool setup` needs an Xcode
xip to build the Darwin SDK, and signing needs an Apple ID. And it builds iOS only, so
the spec's macOS target is parked.

## Diarization models are vendored, not downloaded

**The conflict.** Constraint 1 says the app makes zero outbound requests. Constraint 2
says no third-party SDKs beyond named Swift packages, and names FluidAudio. But
FluidAudio's convenience path fetches its CoreML models over the network on first use.
Following the spec's diarization instructions literally would break the spec's first
constraint, silently, on the first recording.

**What was built.** `DiarizationModelProvider` loads the models from the app bundle
and throws if they are absent. It never reaches for the network.
`Scripts/vendor-diarization-models.sh` copies a downloaded model set into
`Fieldnote/Resources/DiarizationModels` and writes a SHA256 manifest.

**The cost.** A build step, bundle size, and a supply-chain artefact that static
analysis cannot inspect — the same caveat the spec raises about Core AI `.aimodel`
files applies here. Review a model bump the way you would review any dependency bump:
provenance, checksum, and a reason to trust the publisher.

## One capture path, forked three ways — not two capture clients

**The spec** (4.1, 4.2) says to feed transcription from `CaptureInputSequenceProvider`
and run a second raw `AVAudioEngine` tap for diarization.

**What was built.** A single `AVAudioEngine` tap whose buffers fork to all three
consumers: the transcription session, the chunked disk writer, and the diarization
buffer.

**Why.** Two concurrent capture clients on one microphone is a second thing that can
fail, a second format to reconcile, and two independent clocks whose drift shows up as
misaligned speaker labels — the exact failure the `primeMethod = .none` note in the
spec exists to prevent. One tap makes the timeline shared by construction.

**If you change it back:** `CaptureInputSequenceProvider` removes the conversion
plumbing on the transcription side, which is real. Do it only after confirming that
its timestamps share an origin with the raw tap's, and re-run the four-person
relabelling check afterwards.

## SwiftData, and therefore no FTS5

**The spec** (5) says pick SwiftData or GRDB, and asks for FTS5 search across titles,
transcripts and summaries.

**What was built.** SwiftData, with a denormalised lowercase `searchText` column on
`Meeting` and a `contains` predicate.

**Why.** SwiftData has no full-text index. Getting FTS5 means GRDB, which means
hand-writing the schema, migrations and change tracking that SwiftData gives free —
a large cost in v1 for a search feature over one engineer's meetings.

**The trigger to revisit:** search latency on a real corpus, not taste. The
denormalised column is the migration path: it already holds exactly what an FTS5 table
would index.

## The model cites line numbers, not UUIDs

**The spec** (4.5) puts `sourceSegmentID: UUID` on every action item.

**What was built.** The persisted types carry exactly that. The model-facing types
(`DraftActionItem`, `DraftDecision`, `DraftClaim`) carry `sourceLines: [Int]` instead,
and `SummaryGrounder` maps them back — discarding any claim whose citation does not
resolve.

**Why.** Asking a 3B–20B model to copy a UUID accurately is asking it to invent one,
and an unresolvable citation is worse than no citation because it looks like grounding.
Line numbers are global across the transcript, so a citation stays unambiguous even
though the model only ever sees one chunk.

`Outcome.discardedClaims` counts what was thrown away, so a prompt change that wrecks
grounding shows up as a number rather than as quietly thinner summaries.

## Both model tiers currently resolve to the on-device default

`OnDeviceModel.pinnedModel(for:)` returns the on-device model for both `.core` and
`.coreAdvanced`. The tier split is in the call sites already — classification uses
`.core`, summarisation uses `.coreAdvanced` — so selecting the larger on-device tier
is a one-line change in one function once the SDK symbol is confirmed.

What must never change there: the returned model executes on this device, and no path
can substitute Private Cloud Compute or a third-party provider.

## Context budget falls back until measured

`ContextBudget.measure` returns a conservative 2,800-token fallback and records
`isMeasured: false`, which is logged. The measured branch is written and waiting for
the context-size and token-count symbols.

A hardcoded budget either wastes context on a capable phone or overflows on a modest
one, and overflow shows up as a summary section that silently went missing — so the
fallback is deliberately small rather than optimistic.

## Contextual strings are wired but unproven

`AnalysisContext.contextualStrings` is set from `MSPVocabulary`. Apple documents it
against `DictationTranscriber`, and reports of its effect on the long-form
`SpeechTranscriber` path range from weak to none.

It is a few lines, so it is measured rather than argued about: benchmark keyword recall
against a fixed recording with and without it. If it does nothing, leave the terms
mangled in v1 — the correction layer that fixes this properly is v2, and half of it is
worse than none of it. The word list stays either way, as the seed for that work.

## Segments the pipeline cannot label stay "Unknown"

`SpeakerAlignment` assigns the speaker with the greatest time overlap, and leaves
`speakerID == nil` when there is no overlap at all. It does not guess.

A confident wrong label does not invite correction; an "Unknown" does, and it is one
long-press from being fixed. Overlapping speech is weak in every implementation —
manual reassignment is the answer, not a cleverer heuristic.

## Manual edits outrank the pipeline, permanently

Any segment with `editedByUser` set survives re-diarization, re-transcription, and
`MeetingStore.replaceSegments`. Re-running the pipeline over a meeting someone has
already corrected must not silently undo their work.

## Failure is visible, never silent

- A chunk that trips a guardrail retries on a shorter neutral prompt, and either way
  lands in `MeetingSummary.degradedChunks` with its time range. The UI shows the gap.
- A roll-up that fails falls back to the chunk points rather than an empty overview.
- A background task that cannot be submitted runs in-process instead of dropping the
  work; the checkpoints make the next launch pick it up.
- A meeting whose pipeline failed keeps its `failureMessage` and shows it in the list.

The rule behind all four: the user should never discover a missing section by noticing
it is missing.

## Consent is a sentence, not a workflow

v1 shows a plain-language line in the recorder about NSW's all-party consent
requirement, and records that it was shown. It does not gate recording, log attendees,
or block sharing.

That is spec 7 as written: v1 relies on the existing verbal process. The consent log,
the per-meeting badge and the gate on sharing raw transcript or audio are specified in
11.5 and deferred whole — building a third of it would create the appearance of a
compliance feature without the substance.

## Speaker embeddings are stored despite being unused

`Speaker.embedding` is dead weight in v1 and deliberately so. v2's cross-meeting
matching needs a corpus, and backfilling embeddings from archived audio is far more
painful than storing them now. The backup archive carries them too, so a restored
device does not start from an empty corpus.

## No App Intents at all, not even control intents

The spec permits `StartRecording` / `StopRecording` style control intents provided they
carry no meeting content. v1 ships none.

Recording starts from the app, so the convenience is small, and shipping zero intents
makes the rest of the policy trivially true rather than dependent on everyone
remembering what an intent is allowed to return. The prohibitions are still written
down — in the README, in `PolicyTests`, and in `policy-check.sh` — because the moment
someone adds a convenience intent they need the rules already in place.
