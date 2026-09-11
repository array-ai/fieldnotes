import Foundation

/// The MSP stack, fed to `AnalysisContext.contextualStrings` so its effect on the
/// long-form path can be measured against a fixed recording (spec 4.3).
///
/// This is a benchmark input, not a correction layer. If contextual strings turn out
/// to do nothing on `SpeechTranscriber`, this list stays as the seed for the v2 term
/// list (spec 11.1) and nothing else changes.
public enum MSPVocabulary {
    public static let contextualStrings: [String] = [
        // Network
        "Ubiquiti", "UniFi", "UniFi Dream Machine", "UDM Pro", "VLAN", "SSID", "PoE",
        // Security
        "Huntress", "Bitdefender", "GravityZone", "Perception Point", "Inky",
        "1Password", "Entra", "Intune", "Defender",
        // Platform
        "Microsoft 365", "Exchange Online", "SharePoint", "OneDrive", "Azure",
        // Tooling
        "Hudu", "HaloPSA", "NinjaOne", "NinjaRMM", "Acronis", "Acronis Cyber Infrastructure",
        // Hardware
        "HPE", "ProLiant", "iLO", "Aruba",
        // Local
        "Coffs Harbour"
    ]
}
