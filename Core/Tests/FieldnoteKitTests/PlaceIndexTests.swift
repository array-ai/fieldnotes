import FieldnoteKit
import Foundation
import Testing

@Suite("Offline place names")
struct PlaceIndexTests {

    private let index = PlaceIndex(table: """
        R\tNew South Wales\tAustralia
        R\tVictoria\tAustralia
        -33.886\t151.211\tSurry Hills\t0
        -33.868\t151.209\tSydney\t0
        -37.814\t144.963\tMelbourne\t1
        -32.595\t149.587\tMudgee\t0

        """)

    @Test("Parses places and regions")
    func parses() {
        #expect(index.count == 4)
    }

    @Test("Picks the nearest town with its state and country")
    func nearest() throws {
        let place = try #require(index.nearest(latitude: -33.887, longitude: 151.212))
        #expect(place.name == "Surry Hills")
        #expect(place.displayName == "Surry Hills, New South Wales, Australia")
        #expect(place.distance < 200)
    }

    @Test("Outside a town, the name says near")
    func near() throws {
        let place = try #require(index.nearest(latitude: -32.70, longitude: 149.70))
        #expect(place.name == "Mudgee")
        #expect(place.displayName.hasPrefix("near Mudgee"))
    }

    @Test("Nothing within 100 km gives no name rather than a misleading one")
    func tooFar() {
        #expect(index.nearest(latitude: 0, longitude: 0) == nil)
        #expect(PlaceIndex(table: "").nearest(latitude: -33.9, longitude: 151.2) == nil)
    }
}
