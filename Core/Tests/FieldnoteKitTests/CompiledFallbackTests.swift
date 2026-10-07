import FieldnoteKit
import Foundation
import Testing

@Suite("Compiled build fallback")
struct CompiledFallbackTests {

    private func defaults() -> UserDefaults {
        let name = "CompiledFallbackTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test("A compiled build knows its portable model")
    func portable() {
        #expect(ModelPack.ID.minicpm5_2bH17p.portable == .minicpm5_2b)
        #expect(ModelPack.ID.minicpm5H17p.portable == .minicpm5)
        #expect(ModelPack.ID.lfm2_5H17p.portable == .lfm2_5)
        #expect(ModelPack.ID.minicpm5_2b.portable == nil)
        #expect(ModelPack.ID.parakeetV2.portable == nil)
    }

    @Test("Two failures in a row switch to the portable model; a success resets")
    func fallback() {
        let store = defaults()
        #expect(CompiledFallback.pack(for: .minicpm5_2b, architecture: "h17p", defaults: store) == .minicpm5_2bH17p)
        #expect(!CompiledFallback.recordFailure(.minicpm5_2bH17p, defaults: store))
        CompiledFallback.recordSuccess(.minicpm5_2bH17p, defaults: store)
        #expect(!CompiledFallback.recordFailure(.minicpm5_2bH17p, defaults: store))
        #expect(CompiledFallback.recordFailure(.minicpm5_2bH17p, defaults: store))
        #expect(CompiledFallback.pack(for: .minicpm5_2b, architecture: "h17p", defaults: store) == .minicpm5_2b)
        // No build for this chip: the portable model, as before.
        #expect(CompiledFallback.pack(for: .minicpm5_2b, architecture: "h99x", defaults: store) == .minicpm5_2b)
        // A portable model's failures aren't counted.
        #expect(!CompiledFallback.recordFailure(.minicpm5_2b, defaults: store))
        #expect(!CompiledFallback.recordFailure(.minicpm5_2b, defaults: store))
    }
}
