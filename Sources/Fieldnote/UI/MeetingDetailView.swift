import FieldnoteKit
import SwiftUI

struct MeetingDetailView: View {
    @Environment(AppModel.self) private var model
    let meetingID: UUID

    @State private var meeting: MeetingSnapshot?
    @State private var tab: Tab = .summary
    @State private var editingSegment: TranscriptSegment?
    @State private var relabelling: TranscriptSegment?
    @State private var scrollTarget: UUID?
    @State private var composing = false

    enum Tab: String, CaseIterable { case summary, transcript }

    var body: some View {
        Group {
            if let meeting {
                content(meeting)
            } else {
                ProgressView().task { await load() }
            }
        }
        .navigationTitle(meeting?.title ?? "Meeting")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let meeting {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        SharePayloadMenu(meeting: meeting)
                        Divider()
                        Button("Share meeting…", systemImage: "square.and.arrow.up.on.square") {
                            composing = true
                        }
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(isPresented: $composing) {
            if let meeting { ComposedShareView(meeting: meeting) }
        }
        .sheet(item: $editingSegment) { segment in
            SegmentEditor(segment: segment) { text in
                Task {
                    try? await model.store.updateSegmentText(segment.id, to: text)
                    await load()
                }
            }
        }
        .confirmationDialog("Change speaker", isPresented: .constant(relabelling != nil), titleVisibility: .visible) {
            if let segment = relabelling, let meeting {
                ForEach(speakerLabels(meeting), id: \.self) { label in
                    Button(meeting.speakerNames[label] ?? label) {
                        Task {
                            try? await model.store.relabelSegment(segment.id, to: label)
                            relabelling = nil
                            await load()
                        }
                    }
                }
                Button("Unknown") {
                    Task {
                        try? await model.store.relabelSegment(segment.id, to: nil)
                        relabelling = nil
                        await load()
                    }
                }
            }
            Button("Cancel", role: .cancel) { relabelling = nil }
        }
    }

    private func content(_ meeting: MeetingSnapshot) -> some View {
        VStack(spacing: 0) {
            if meeting.state != .complete {
                ProcessingStatusBanner(meeting: meeting)
            }
            Picker("View", selection: $tab) {
                Text("Summary").tag(Tab.summary)
                Text("Transcript").tag(Tab.transcript)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            ScrollViewReader { proxy in
                List {
                    switch tab {
                    case .summary:
                        SummarySections(meeting: meeting) { segmentID in
                            // Tapping a citation jumps to the line it came from
                            // (spec 4.5). Every claim has one or it was not saved.
                            tab = .transcript
                            scrollTarget = segmentID
                        }
                    case .transcript:
                        TranscriptSections(
                            meeting: meeting,
                            onEdit: { editingSegment = $0 },
                            onRelabel: { relabelling = $0 }
                        )
                    }
                }
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                    scrollTarget = nil
                }
            }
        }
    }

    private func speakerLabels(_ meeting: MeetingSnapshot) -> [String] {
        let fromSegments = Set(meeting.segments.compactMap(\.speakerID))
        return Array(fromSegments.union(meeting.speakerNames.keys)).sorted()
    }

    private func load() async {
        meeting = try? await model.store.meetingSnapshot(meetingID)
    }
}

struct ProcessingStatusBanner: View {
    let meeting: MeetingSnapshot

    var body: some View {
        HStack(spacing: 8) {
            if meeting.state == .failed {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(meeting.failureMessage ?? "Processing failed. It will resume from the last completed stage.")
            } else {
                ProgressView().controlSize(.small)
                Text(statusText)
            }
            Spacer()
        }
        .font(.footnote)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }

    private var statusText: String {
        switch meeting.state {
        case .queued: "Queued for processing"
        case .transcribing: "Transcribing…"
        case .diarizing: "Identifying speakers…"
        case .summarising: "Summarising…"
        case .recording: "Recording"
        default: ""
        }
    }
}

struct SummarySections: View {
    let meeting: MeetingSnapshot
    var onCitation: (UUID) -> Void

    var body: some View {
        if let summary = meeting.summary {
            if !summary.overview.isEmpty {
                Section("Overview") { Text(summary.overview) }
            }
            if !summary.decisions.isEmpty {
                Section("Decisions") {
                    ForEach(summary.decisions) { decision in
                        Button { onCitation(decision.sourceSegmentID) } label: {
                            CitedRow(text: decision.statement, time: time(decision.sourceSegmentID))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !summary.actionItems.isEmpty {
                Section("Action items") {
                    ForEach(summary.actionItems) { item in
                        Button { onCitation(item.sourceSegmentID) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                CitedRow(text: item.task, time: time(item.sourceSegmentID))
                                HStack(spacing: 8) {
                                    if let owner = item.owner { Label(owner, systemImage: "person") }
                                    if let due = item.dueDate { Label(due, systemImage: "calendar") }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !summary.openQuestions.isEmpty {
                Section("Open questions") {
                    ForEach(summary.openQuestions) { question in
                        Button { onCitation(question.sourceSegmentID) } label: {
                            CitedRow(text: question.text, time: time(question.sourceSegmentID))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !summary.mentionedSystems.isEmpty {
                Section("Systems mentioned") {
                    Text(summary.mentionedSystems.joined(separator: ", "))
                        .font(.callout)
                }
            }
            if !summary.degradedChunks.isEmpty {
                Section("Coverage") {
                    ForEach(summary.degradedChunks, id: \.chunkIndex) { chunk in
                        Label(
                            "\(Timecode.short(chunk.startTime))–\(Timecode.short(chunk.endTime)) summarised with a reduced prompt"
                                + (chunk.recovered ? "" : " and could not be summarised"),
                            systemImage: "exclamationmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Section {
                ContentUnavailableView("No summary yet", systemImage: "text.badge.plus")
            }
        }
    }

    private func time(_ segmentID: UUID) -> String? {
        meeting.segments.first { $0.id == segmentID }.map { Timecode.short($0.start) }
    }
}

struct CitedRow: View {
    let text: String
    let time: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
            Spacer(minLength: 8)
            if let time {
                Text(time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tint)
            }
        }
    }
}

struct TranscriptSections: View {
    let meeting: MeetingSnapshot
    var onEdit: (TranscriptSegment) -> Void
    var onRelabel: (TranscriptSegment) -> Void

    var body: some View {
        Section {
            ForEach(meeting.segments) { segment in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(speakerName(segment))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(colour(segment))
                        Text(Timecode.short(segment.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if segment.editedByUser {
                            Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(segment.text)
                }
                .id(segment.id)
                .contextMenu {
                    Button("Change speaker", systemImage: "person.crop.circle") { onRelabel(segment) }
                    Button("Edit text", systemImage: "pencil") { onEdit(segment) }
                }
            }
        }
    }

    private func speakerName(_ segment: TranscriptSegment) -> String {
        guard let id = segment.speakerID else { return "Unknown" }
        return meeting.speakerNames[id] ?? id
    }

    private func colour(_ segment: TranscriptSegment) -> Color {
        guard let id = segment.speakerID else { return .secondary }
        let labels = Array(Set(meeting.segments.compactMap(\.speakerID)))
        let rgb = SpeakerPalette.colours[SpeakerPalette.index(for: id, among: labels)]
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

struct SegmentEditor: View {
    let segment: TranscriptSegment
    var onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(segment: TranscriptSegment, onSave: @escaping (String) -> Void) {
        self.segment = segment
        self.onSave = onSave
        _text = State(initialValue: segment.text)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding()
                .navigationTitle(Timecode.short(segment.start))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            onSave(text)
                            dismiss()
                        }
                    }
                }
        }
    }
}
