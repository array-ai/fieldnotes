import Foundation
import FoundationModels

/// The device floor is Apple Intelligence, not iOS 27 (spec 10). iPhone 15 Pro /
/// iPhone 16 or later. We do not sniff model identifiers — we ask the framework
/// whether the on-device model is usable, which is the thing we actually depend on.
///
/// There is no degraded transcribe-only mode. A Fieldnote that cannot summarise is
/// not Fieldnote, and a second code path is a second thing to test and break.
public enum DeviceCapability {

    public enum Status: Equatable, Sendable {
        case ready
        /// Hardware cannot run Apple Intelligence at all. Terminal — refuse at launch.
        case unsupportedHardware
        /// Supported hardware, but the user has not turned Apple Intelligence on.
        case appleIntelligenceOff
        /// Supported hardware, model assets still downloading.
        case modelNotReady
        /// Region or policy restriction (spec 10: EU / China end-user availability).
        case unavailableInRegion
        case unknown(String)

        public var allowsRecording: Bool { self == .ready }
    }

    public static func current() -> Status {
        switch OnDeviceModel.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            return map(reason)
        @unknown default:
            return .unknown("Unrecognised availability state.")
        }
    }

    private static func map(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> Status {
        switch reason {
        case .deviceNotEligible:
            return .unsupportedHardware
        case .appleIntelligenceNotEnabled:
            return .appleIntelligenceOff
        case .modelNotReady:
            return .modelNotReady
        @unknown default:
            // Region restrictions surface here on some builds. Treat anything we do not
            // recognise as blocking rather than guessing our way into a broken pipeline.
            return .unknown("The on-device model is unavailable on this device.")
        }
    }
}

extension DeviceCapability.Status {
    public var headline: String {
        switch self {
        case .ready: "Ready"
        case .unsupportedHardware: "This iPhone cannot run Fieldnote"
        case .appleIntelligenceOff: "Turn on Apple Intelligence"
        case .modelNotReady: "Preparing the on-device model"
        case .unavailableInRegion: "Not available in this region"
        case .unknown: "On-device model unavailable"
        }
    }

    public var explanation: String {
        switch self {
        case .ready:
            return ""
        case .unsupportedHardware:
            return """
            Fieldnote does everything on the device: transcription, speaker \
            identification and summarising. That needs Apple Intelligence hardware, \
            which means iPhone 15 Pro, iPhone 16 or later.

            There is no cut-down mode. A version that could not summarise would not \
            be worth shipping.
            """
        case .appleIntelligenceOff:
            return """
            Fieldnote summarises meetings using the on-device model. Turn on Apple \
            Intelligence in Settings, then reopen Fieldnote.
            """
        case .modelNotReady:
            return """
            iOS is still downloading the on-device model. This happens once. Leave the \
            phone on Wi-Fi and charging, then reopen Fieldnote.
            """
        case .unavailableInRegion:
            return """
            Apple Intelligence is not available in this region, so Fieldnote cannot \
            summarise here.
            """
        case .unknown(let detail):
            return detail
        }
    }
}
