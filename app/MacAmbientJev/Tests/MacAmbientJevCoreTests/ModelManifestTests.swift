import Foundation
import Testing
import MacAmbientJevCore

private let commit = String(repeating: "a", count: 40)

private func entry(files: [(String, Data)]) -> ModelManifestEntry {
    ModelManifestEntry(
        repository: "owner/repo",
        commit: commit,
        files: files.map {
            ModelManifestFile(
                name: $0.0, role: "r", byteCount: Int64($0.1.count),
                sha256: FileSHA256.hexDigest(of: $0.1)
            )
        }
    )
}

private func makeDirectory(_ files: [(String, Data)]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "model-verifier-\(UUID().uuidString)", directoryHint: .isDirectory)
    for (name, data) in files {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url)
    }
    return root
}

private let sample: [(String, Data)] = [
    ("a.bin", Data("alpha".utf8)),
    ("nested/b.mlmodelc/weights/w.bin", Data("beta".utf8))
]

@Test
func matchingDirectoryVerifies() throws {
    let root = try makeDirectory(sample)
    defer { try? FileManager.default.removeItem(at: root) }
    try ModelVerifier.verify(directory: root, entry: entry(files: sample))
}

@Test
func missingFileNamesTheFile() throws {
    let root = try makeDirectory([sample[0]])
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: ModelVerificationError.missing(file: "nested/b.mlmodelc/weights/w.bin")) {
        try ModelVerifier.verify(directory: root, entry: entry(files: sample))
    }
}

@Test
func wrongSizeIsReportedBeforeHashing() throws {
    let root = try makeDirectory([sample[0], (sample[1].0, Data("be".utf8))])
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: ModelVerificationError.wrongSize(file: sample[1].0, expected: 4, actual: 2)) {
        try ModelVerifier.verify(directory: root, entry: entry(files: sample))
    }
}

@Test
func sameSizeDifferentContentFailsTheHash() throws {
    let root = try makeDirectory([sample[0], (sample[1].0, Data("xxxx".utf8))])
    defer { try? FileManager.default.removeItem(at: root) }
    let expected = entry(files: sample)
    #expect(throws: ModelVerificationError.wrongHash(
        file: sample[1].0,
        expected: expected.files[1].sha256,
        actual: FileSHA256.hexDigest(of: Data("xxxx".utf8))
    )) {
        try ModelVerifier.verify(directory: root, entry: expected)
    }
}

@Test
func symlinkedFileAndSymlinkedParentAreRejected() throws {
    let root = try makeDirectory(sample)
    let outside = try makeDirectory(sample)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    let fileLink = root.appending(path: "a.bin")
    try FileManager.default.removeItem(at: fileLink)
    try FileManager.default.createSymbolicLink(
        at: fileLink, withDestinationURL: outside.appending(path: "a.bin")
    )
    #expect(throws: ModelVerificationError.notRegularFile(file: "a.bin")) {
        try ModelVerifier.verify(directory: root, entry: entry(files: sample))
    }

    let parentLink = root.appending(path: "nested")
    try FileManager.default.removeItem(at: parentLink)
    try FileManager.default.createSymbolicLink(
        at: parentLink, withDestinationURL: outside.appending(path: "nested")
    )
    #expect(throws: ModelVerificationError.notRegularFile(file: sample[1].0)) {
        try ModelVerifier.verify(directory: root, entry: entry(files: [sample[1]]))
    }
}

private func manifestJSON(commit: String = commit, files: String) -> Data {
    Data("""
    {"m": {"repository": "owner/repo", "commit": "\(commit)", "files": [\(files)]}}
    """.utf8)
}

private func fileJSON(name: String, byteCount: Int = 5, sha: String = String(repeating: "b", count: 64)) -> String {
    #"{"name": "\#(name)", "role": "r", "byteCount": \#(byteCount), "sha256": "\#(sha)"}"#
}

@Test
func manifestDecodesRelativePaths() throws {
    let entries = try ModelManifest.decode(manifestJSON(files: fileJSON(name: "a/b.mlmodelc/c.bin")))
    #expect(entries["m"]?.files.first?.name == "a/b.mlmodelc/c.bin")
}

@Test
func manifestRejectsInvalidEntries() {
    let invalid: [Data] = [
        manifestJSON(files: fileJSON(name: "/abs.bin")),
        manifestJSON(files: fileJSON(name: "../up.bin")),
        manifestJSON(files: fileJSON(name: "a/../b.bin")),
        manifestJSON(files: fileJSON(name: "a//b.bin")),
        manifestJSON(files: fileJSON(name: "a.bin", byteCount: 0)),
        manifestJSON(files: fileJSON(name: "a.bin", sha: "ABC")),
        manifestJSON(files: fileJSON(name: "a.bin") + "," + fileJSON(name: "a.bin")),
        manifestJSON(commit: "main", files: fileJSON(name: "a.bin")),
        manifestJSON(files: "")
    ]
    for data in invalid {
        #expect(throws: ModelManifestError.self) { try ModelManifest.decode(data) }
    }
}
