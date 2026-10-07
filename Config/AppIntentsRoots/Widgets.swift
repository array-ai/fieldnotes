// Replaces xtool's empty stub.c in the widget extension target (release workflow),
// so the Control Centre / Action button control's intent is in the extension's
// Metadata.appintents too.
import AppIntents
import FieldnoteWidgets

struct FieldnoteWidgetsIntentsRoot: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [FieldnoteWidgetsIntents.self] }
}
