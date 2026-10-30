import Testing
@testable import MacAmbientJevEngine

@Suite struct WindowsAcceleratorPackageTests {
    @Test func testExactPathSetMatchesCaseInsensitivelyAcrossSeparators() throws {
        try validateAcceleratorPathSet(libraryPath: "C:/Packages/Head/plugin.dll", headRoot: "c:\\packages\\head",
            declaredPaths: ["C:/Packages/Head/plugin.dll", "C:/Packages/Head/dep.dll"],
            actualPaths: ["c:\\PACKAGES\\HEAD\\PLUGIN.DLL", "c:/packages/head/DEP.dll"])
    }

    @Test func testExtraFileIsRejected() {
        do { try validateAcceleratorPathSet(libraryPath: "C:/Packages/Head/plugin.dll", headRoot: "C:/Packages/Head",
            declaredPaths: ["C:/Packages/Head/plugin.dll"], actualPaths: ["C:/Packages/Head/plugin.dll", "C:/Packages/Head/extra.dll"]); Issue.record("Expected extra package path to be rejected.") }
        catch { #expect(error.localizedDescription.contains("extra")) }
    }

    @Test func testMissingFileIsRejected() {
        do { try validateAcceleratorPathSet(libraryPath: "C:/Packages/Head/plugin.dll", headRoot: "C:/Packages/Head",
            declaredPaths: ["C:/Packages/Head/plugin.dll", "C:/Packages/Head/dep.dll"], actualPaths: ["C:/Packages/Head/plugin.dll"]); Issue.record("Expected missing package path to be rejected.") }
        catch { #expect(error.localizedDescription.contains("missing")) }
    }

    @Test func testLibraryOutsideHeadRootIsRejected() {
        do { try validateAcceleratorPathSet(libraryPath: "C:/Packages/Other/plugin.dll", headRoot: "C:/Packages/Head",
            declaredPaths: ["C:/Packages/Other/plugin.dll"], actualPaths: ["C:/Packages/Other/plugin.dll"]); Issue.record("Expected library outside head root to be rejected.") }
        catch { #expect(error.localizedDescription.contains("outside head")) }
    }
}
