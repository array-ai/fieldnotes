import FieldnoteKit
import Foundation
#if os(iOS)
import CoreLocation
import MapKit
#endif

/// Turns a meeting's coordinates into a name people can read and search for.
///
/// Two sources, in this order:
///
/// 1. **Offline, always.** The nearest suburb or town from the bundled GeoNames
///    table (`PlaceIndex`). No network request.
/// 2. **Apple Maps, only when turned on** in Settings (off by default). A nearby
///    business or building name, or the street address. This sends the coordinates
///    to Apple, and only the coordinates.
///
/// This is the only file allowed to call Apple's geocoding or place search — the
/// policy checks enforce it — so what leaves the device for location is in one place.
public actor PlaceNamer {

    public static let shared = PlaceNamer()

    private var index: PlaceIndex?
    private let debug = DebugLog.shared

    // MARK: - Offline

    public func offlineName(latitude: Double, longitude: Double) -> String? {
        loadedIndex()?.nearest(latitude: latitude, longitude: longitude)?.displayName
    }

    private func loadedIndex() -> PlaceIndex? {
        if let index { return index }
        let started = ContinuousClock.now
        guard let url = Bundle.main.resourceURL?.appending(path: "Places/places.deflate"),
              let packed = try? Data(contentsOf: url),
              let unpacked = try? (packed as NSData).decompressed(using: .zlib) as Data,
              let table = String(data: unpacked, encoding: .utf8) else {
            debug.log("place", "offline place table missing from the app bundle")
            return nil
        }
        let loaded = PlaceIndex(table: table)
        debug.log("place", "loaded \(loaded.count) offline places in \(DebugLog.elapsed(since: started))")
        index = loaded
        return loaded
    }

    // MARK: - Apple Maps (opt-in)

    /// A business or building within ~75 m, else the street address. Nil on any
    /// failure: a missing name is never a reason to block anything.
    ///
    /// Main actor and static: MapKit's request and response types aren't Sendable,
    /// so they stay on one actor and only the resulting string leaves it.
    @MainActor
    public static func appleMapsName(latitude: Double, longitude: Double) async -> String? {
        #if os(iOS)
        let debug = DebugLog.shared
        let started = ContinuousClock.now
        let location = CLLocation(latitude: latitude, longitude: longitude)

        var business: String?
        let poiRequest = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: 75)
        if let response = try? await MKLocalSearch(request: poiRequest).start() {
            business = response.mapItems
                .min { $0.location.distance(from: location) < $1.location.distance(from: location) }?
                .name
        }

        var area: String?
        var street: String?
        if let request = MKReverseGeocodingRequest(location: location),
           let item = (try? await request.mapItems)?.first {
            area = item.addressRepresentations?.cityWithContext
            street = item.address?.shortAddress
        }

        let name: String? = switch (business, street, area) {
        case let (business?, _, area?): "\(business), \(area)"
        case let (business?, street?, nil): "\(business), \(street)"
        case let (business?, nil, nil): business
        case let (nil, street?, _): street
        case let (nil, nil, area?): area
        default: nil
        }
        debug.log("place", "Apple Maps lookup \(name == nil ? "found nothing" : "found a name") in \(DebugLog.elapsed(since: started))")
        return name
        #else
        return nil
        #endif
    }
}
