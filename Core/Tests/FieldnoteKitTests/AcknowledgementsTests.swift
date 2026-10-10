import FieldnoteKit
import Foundation
import Testing

/// Licences that require their text to ship with the app are only met if every
/// model and library is listed and every file named is really there.
@Suite("Acknowledgements")
struct AcknowledgementsTests {

    private var licences: URL {
        PolicySourceScanner.repositoryRoot.appending(path: "Resources/\(Acknowledgement.folder)")
    }

    @Test("Every licence and notice file named exists")
    func filesExist() {
        for entry in Acknowledgement.all {
            for file in [entry.licenceFile] + (entry.noticeFile.map { [$0] } ?? []) {
                let path = licences.appending(path: file).path(percentEncoded: false)
                #expect(FileManager.default.fileExists(atPath: path), "\(entry.name): \(file) is missing")
            }
        }
    }

    @Test("Every downloadable model's repo is credited")
    func downloadableModelsListed() {
        let credited = Set(Acknowledgement.all.flatMap(\.repos))
        for pack in ModelPack.catalog {
            #expect(credited.contains(pack.repo), "\(pack.name) (\(pack.repo)) has no acknowledgement")
        }
    }

    @Test("A model's licence matches the catalog's")
    func modelLicencesMatch() {
        let files = ["CC-BY-4.0": "CC-BY-4.0.txt", "OpenMDW-1.1": "OpenMDW-1.1.txt", "Apache-2.0": "Apache-2.0.txt"]
        for pack in ModelPack.catalog {
            let file = files[pack.license]
            #expect(file != nil, "\(pack.name): no licence text for \(pack.license)")
            // The shared publicarray repo holds builds of several models, so one of
            // the entries crediting the repo has to carry the pack's licence.
            let entries = Acknowledgement.all.filter { $0.repos.contains(pack.repo) }
            #expect(entries.contains { $0.licenceFile == file }, "\(pack.name): acknowledged under a different licence")
        }
    }

    @Test("Every Swift package the app resolves is credited")
    func packagesListed() throws {
        let url = PolicySourceScanner.repositoryRoot.appending(path: "Package.resolved")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let pins = try #require(json["pins"] as? [[String: Any]])
        let credited = Set(Acknowledgement.all.compactMap(\.package))
        for identity in pins.compactMap({ $0["identity"] as? String }) {
            #expect(credited.contains(identity), "\(identity) is in Package.resolved but not in Acknowledgements")
        }
    }
}
