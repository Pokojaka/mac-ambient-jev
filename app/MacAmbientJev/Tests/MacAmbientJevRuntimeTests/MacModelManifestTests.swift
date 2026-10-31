import Testing
@testable import MacAmbientJevRuntime

@Test
func bundledManifestDecodesAndPinsEveryModel() throws {
    let manifest = try MacModelManifest.bundled()
    #expect(Set(manifest.keys) == Set(MacModel.allCases))
    for entry in manifest.values {
        #expect(!entry.files.isEmpty)
    }
}
