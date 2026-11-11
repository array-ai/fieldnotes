import ActivityKit
import FieldnoteKit
import FieldnoteShared
import SwiftUI
import WidgetKit

/// Lock Screen and Dynamic Island presentation for an in-progress recording
/// (spec 4.1).
///
/// Shows elapsed time, a level meter and the meeting title. No transcript, ever: the
/// Lock Screen is visible to whoever is in the room, which on a site visit is the
/// client.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenView(context: context)
                .padding()
                .activityBackgroundTint(.black.opacity(0.6))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Recording", systemImage: "mic.fill")
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RecordedTime(state: context.state)
                        .font(.caption.monospacedDigit())
                        .frame(maxWidth: 64, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    MeterBar(level: context.state.level, isPaused: context.state.isPaused)
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.circle" : "record.circle")
                    // Spelled out: `.secondary` is a HierarchicalShapeStyle and
                    // `.red` is a Color, so the ternary has no common type.
                    .foregroundStyle(context.state.isPaused ? Color.secondary : Color.red)
            } compactTrailing: {
                RecordedTime(state: context.state)
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth: 48, alignment: .trailing)
            } minimal: {
                Image(systemName: "record.circle").foregroundStyle(.red)
            }
        }
    }

}

/// Recorded time: a clock that runs by itself while recording, so it stays right
/// between the app's updates, and the time it stopped at while paused.
struct RecordedTime: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        if state.isPaused {
            Text(Timecode.short(state.elapsed))
        } else {
            Text(state.startedAt, style: .timer)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct LockScreenView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(context.attributes.title, systemImage: "record.circle")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                RecordedTime(state: context.state)
                    .font(.headline.monospacedDigit())
                    .frame(maxWidth: 80, alignment: .trailing)
            }
            MeterBar(level: context.state.level, isPaused: context.state.isPaused)
            Text(context.state.isPaused ? "Paused" : "Recording on this device")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct MeterBar: View {
    let level: Double
    let isPaused: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(isPaused ? Color.secondary : Color.red)
                    .frame(width: proxy.size.width * min(1, max(0.02, level)))
            }
        }
        .frame(height: 6)
    }
}
