import Foundation

/// A place name for a coordinate, without a network request.
///
/// Built from the bundled GeoNames table (`Resources/Places`, see
/// `Scripts/build-places.py`): every populated place with 500+ people. The answer is
/// the nearest suburb or town, its state and its country — enough to search for and
/// to give a meeting context. Building and business names need Apple Maps, which is
/// a separate, opt-in lookup in the app.
public struct PlaceIndex: Sendable {

    public struct Place: Sendable, Equatable {
        public var name: String
        public var region: String
        public var country: String
        /// Straight-line distance from the queried coordinate, in metres.
        public var distance: Double

        /// "Surry Hills, New South Wales, Australia", or "near Mudgee, …" when the
        /// nearest town is more than `nearThreshold` away.
        public var displayName: String {
            let parts = [name, region, country].filter { !$0.isEmpty }
            let joined = parts.joined(separator: ", ")
            return distance > PlaceIndex.nearThreshold ? "near \(joined)" : joined
        }
    }

    /// Beyond this the coordinate is outside the town, so the name says "near".
    public static let nearThreshold: Double = 5_000
    /// Beyond this the nearest town is no useful answer at all.
    public static let maxDistance: Double = 100_000

    private var latitudes: [Double] = []
    private var longitudes: [Double] = []
    private var names: [String] = []
    private var regionIndices: [Int] = []
    private var regions: [(region: String, country: String)] = []

    public var count: Int { names.count }

    /// Parses the decompressed table (format in `Scripts/build-places.py`).
    public init(table: String) {
        for line in table.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if fields.first == "R", fields.count == 3 {
                regions.append((String(fields[1]), String(fields[2])))
                continue
            }
            guard fields.count == 4,
                  let lat = Double(fields[0]), let lon = Double(fields[1]),
                  let region = Int(fields[3]) else { continue }
            latitudes.append(lat)
            longitudes.append(lon)
            names.append(String(fields[2]))
            regionIndices.append(region)
        }
    }

    /// The nearest place, or nil if there is none within `maxDistance`.
    public func nearest(latitude: Double, longitude: Double) -> Place? {
        guard !names.isEmpty else { return nil }
        // Equirectangular distance is plenty to rank candidates; the winner gets an
        // exact great-circle distance.
        let cosLat = cos(latitude * .pi / 180)
        var best = -1
        var bestScore = Double.infinity
        for i in 0..<latitudes.count {
            let dLat = latitudes[i] - latitude
            var dLon = abs(longitudes[i] - longitude)
            if dLon > 180 { dLon = 360 - dLon }
            let score = dLat * dLat + (dLon * cosLat) * (dLon * cosLat)
            if score < bestScore {
                bestScore = score
                best = i
            }
        }
        let distance = Self.haversine(latitude, longitude, latitudes[best], longitudes[best])
        guard distance <= Self.maxDistance else { return nil }
        let region: (region: String, country: String) = regions.indices.contains(regionIndices[best]) ? regions[regionIndices[best]] : ("", "")
        return Place(name: names[best], region: region.region, country: region.country, distance: distance)
    }

    static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }
}
