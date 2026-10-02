import Foundation
import Testing
@testable import MacAmbientJevCore

@Test
func resolvesReferencePathRelativeToManifest() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let references = root.appending(path: "refs")
    try FileManager.default.createDirectory(
        at: references,
        withIntermediateDirectories: true
    )
    let referenceURL = references.appending(path: "sample.txt")
    try "公開鍵暗号\n".write(
        to: referenceURL,
        atomically: true,
        encoding: .utf8
    )

    let manifestURL = root.appending(path: "manifest.json")
    let reference = GoldenCorpusReference(
        path: "refs/sample.txt"
    )

    #expect(
        try reference.resolvedText(
            relativeTo: manifestURL
        ) == "公開鍵暗号\n"
    )
}

@Test
func inlineReferenceTakesPrecedenceOverPath() throws {
    let manifestURL = URL(
        fileURLWithPath: "/tmp/manifest.json"
    )
    let reference = GoldenCorpusReference(
        text: "inline",
        path: "missing.txt"
    )

    #expect(
        try reference.resolvedText(
            relativeTo: manifestURL
        ) == "inline"
    )
}
