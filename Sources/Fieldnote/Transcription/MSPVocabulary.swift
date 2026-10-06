import FieldnoteKit
import Foundation

/// The MSP stack: the built-in custom words. The user's own list (Settings →
/// Transcription → Custom words) extends it; see `CustomWords`.
public enum MSPVocabulary {
    /// The built-in words and the user's, as Apple's model and the word fixer get them.
    public static var current: [String] {
        CustomWords.merged(user: UserDefaults.standard.stringArray(forKey: CustomWords.defaultsKey) ?? [],
                           builtIn: contextualStrings)
    }


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
