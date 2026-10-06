import FieldnoteKit
import Foundation

/// Common MSP products: the built-in custom words. The user's own list (Settings →
/// Transcription → Custom words) extends it; see `CustomWords`.
public enum MSPVocabulary {
    /// The built-in words and the user's, as Apple's model and the word fixer get them.
    public static var current: [String] {
        CustomWords.merged(user: UserDefaults.standard.stringArray(forKey: CustomWords.defaultsKey) ?? [],
                           builtIn: contextualStrings)
    }


    /// Products MSPs commonly use, not any one MSP's stack. Plain English words
    /// ("Teams", "Keeper", "Duo") are left out: as custom words they'd pull ordinary
    /// speech towards them.
    public static let contextualStrings: [String] = [
        // RMM, PSA and documentation
        "Kaseya", "Kaseya VSA", "Kaseya 365", "Datto", "Datto RMM", "Autotask", "IT Glue",
        "BullPhish ID", "Dark Web ID", "RocketCyber", "Graphus", "Unitrends",
        "ConnectWise", "ConnectWise Manage", "ConnectWise Automate", "ScreenConnect",
        "N-able", "N-central", "N-sight", "NinjaOne", "NinjaRMM", "Atera", "Syncro", "SuperOps",
        "HaloPSA", "Hudu", "Liongard", "Rewst", "Pax8", "TeamViewer", "Splashtop",
        // Security
        "Huntress", "SentinelOne", "CrowdStrike", "Bitdefender", "GravityZone", "Sophos",
        "ESET", "Webroot", "Malwarebytes", "ThreatLocker", "Blackpoint", "Arctic Wolf",
        "Microsoft Defender", "Mimecast", "Proofpoint", "Avanan", "Ironscales",
        "Perception Point", "Inky", "DNSFilter", "Cisco Umbrella", "KnowBe4", "Okta",
        // Passwords
        "1Password", "Bitwarden", "LastPass", "Passportal",
        // Backup
        "Acronis", "Veeam", "Axcient", "Backblaze", "Datto BCDR",
        // Microsoft
        "Microsoft 365", "Entra", "Intune", "Exchange Online", "SharePoint", "OneDrive",
        "Azure", "Autopilot", "Purview",
        // Network
        "Ubiquiti", "UniFi", "Meraki", "Fortinet", "FortiGate", "SonicWall", "WatchGuard",
        "Aruba", "pfSense", "VLAN", "SSID",
        // Hardware
        "HPE", "ProLiant", "iLO", "iDRAC", "Synology", "QNAP",
    ]
}
