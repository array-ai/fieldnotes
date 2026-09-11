import SwiftData
import SwiftUI

@main
struct FieldnoteApp: App {

    @State private var model: AppModel
    private let container: ModelContainer

    init() {
        let container: ModelContainer
        do {
            container = try MeetingStore.makeContainer()
        } catch {
            fatalError("Could not open the Fieldnote database: \(error)")
        }
        self.container = container

        let model = AppModel(container: container)
        _model = State(initialValue: model)

        #if os(iOS)
        // Registration must happen before launch completes. Not at the call site —
        // BGTaskScheduler refuses a handler registered later, with an error that
        // reads like a provisioning problem (spec 4.7).
        model.coordinator.registerHandlers()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .modelContainer(container)
                .task { await model.onLaunch() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.capability.allowsRecording {
                MeetingListView()
            } else {
                UnsupportedDeviceView(status: model.capability) {
                    model.refreshCapability()
                }
            }
        }
    }
}
