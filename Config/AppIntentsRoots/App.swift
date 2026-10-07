// Replaces xtool's empty C file in the app target (release workflow), so Xcode
// extracts the App Intents of the packages the app is built from. The app target
// has no code of its own; without a root like this, Metadata.appintents is never
// written and iOS can't run the record intent.
import AppIntents
import Fieldnote

struct FieldnoteAppIntentsRoot: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [FieldnoteIntents.self] }
}
