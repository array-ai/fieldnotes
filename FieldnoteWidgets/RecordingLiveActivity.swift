import ActivityKit
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
                    Label(context.attributes.meetingType.displayName, systemImage: context.attributes.meetingType.symbolName)
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerText(context))
                        .font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    MeterBar(level: context.state.level, isPaused: context.state.isPaused)
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.circle" : "record.circle")
                    .foregroundStyle(context.state.isPaused ? .secondary : .red)
            } compactTrailing: {
                Text(timerText(context)).font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "record.circle").foregroundStyle(.red)
            }
        }
    }

    private func timerText(_ context: ActivityViewContext<RecordingActivityAttributes>) -> String {
        let total = Int(context.state.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
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
                Text(context.state.startedAt, style: .timer)
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
