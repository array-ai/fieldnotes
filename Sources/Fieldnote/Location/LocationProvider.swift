#if os(iOS)
import CoreLocation
#endif
import Foundation

/// One-shot coordinate capture at the moment a recording starts. Opt-in
/// (`Settings.locationEnabled`), and coordinates only: no reverse geocoding, which
/// would be an outbound request to Apple's servers (constraint 1). CoreLocation
/// itself makes no networking call the app's code performs or can be blamed for.
@MainActor
public final class LocationProvider: NSObject {

    #if os(iOS)
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<(latitude: Double, longitude: Double)?, Never>?
    /// Set only while waiting on the system permission prompt, so the delegate's
    /// authorization callback knows to move on to `requestLocation()` rather than
    /// treating an unrelated authorization change as this request's answer.
    private var awaitingAuthorization = false

    public override init() {
        super.init()
        manager.delegate = self
    }

    /// Returns `nil` on denial, timeout, or any failure. Never throws: a missing
    /// location is not a reason to block starting a recording.
    public func currentCoordinate(timeout: Duration = .seconds(5)) async -> (latitude: Double, longitude: Double)? {
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            Task {
                try? await Task.sleep(for: timeout)
                self.finish(nil)
            }
            beginRequest()
        }
    }

    private func beginRequest() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .notDetermined:
            awaitingAuthorization = true
            manager.requestWhenInUseAuthorization()
        default:
            finish(nil)
        }
    }

    private func finish(_ result: (latitude: Double, longitude: Double)?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: result)
    }
    #else
    public override init() { super.init() }

    public func currentCoordinate(timeout: Duration = .seconds(5)) async -> (latitude: Double, longitude: Double)? {
        nil
    }
    #endif
}

#if os(iOS)
extension LocationProvider: CLLocationManagerDelegate {
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard awaitingAuthorization else { return }
        awaitingAuthorization = false
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            finish(nil)
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return finish(nil) }
        finish((coordinate.latitude, coordinate.longitude))
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }
}
#endif
