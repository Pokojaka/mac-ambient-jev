import Foundation
import Testing
@testable import MacAmbientJevPortableRuntime

struct Qwen3ASRModelManifestTests {
    @Test
    func fileLookupIsIndependentOfManifestArrayOrder() throws {
        let source = manifestObject()
        let original = try Qwen3ASRModelSize.decodeManifests(encode(source))
        var reversedObject = source

        for size in Qwen3ASRModelSize.allCases {
            var files = fileRecords(for: size, in: reversedObject)
            files.reverse()
            setFileRecords(files, for: size, in: &reversedObject)
        }

        let reversed = try Qwen3ASRModelSize.decodeManifests(encode(reversedObject))
        for size in Qwen3ASRModelSize.allCases {
            let originalEntry = original[size.rawValue]!
            let reversedEntry = reversed[size.rawValue]!
            for role in Qwen3ASRModelFileRole.allCases {
                #expect(reversedEntry.file(for: role) == originalEntry.file(for: role))
            }
        }
    }

    @Test
    func missingRoleEntriesFailWithTheMissingRole() throws {
        for size in Qwen3ASRModelSize.allCases {
            for role in Qwen3ASRModelFileRole.allCases {
                var manifest = manifestObject()
                var files = fileRecords(for: size, in: manifest)
                files.removeAll { ($0["role"] as? String) == role.rawValue }
                setFileRecords(files, for: size, in: &manifest)

                let failure = decodeFailure(try encode(manifest))
                #expect(failure?.contains(role.rawValue) == true)
            }
        }
    }

    @Test
    func duplicateRoleEntriesFailWithTheDuplicatedRole() throws {
        for size in Qwen3ASRModelSize.allCases {
            for role in Qwen3ASRModelFileRole.allCases {
                var manifest = manifestObject()
                var files = fileRecords(for: size, in: manifest)
                var duplicate = files.first { ($0["role"] as? String) == role.rawValue }!
                let originalName = duplicate["name"] as? String
                let duplicateName = "duplicate-\(role.rawValue).bin"
                duplicate["name"] = duplicateName
                #expect(duplicateName != originalName)
                files.append(duplicate)
                setFileRecords(files, for: size, in: &manifest)

                let failure = decodeFailure(try encode(manifest))
                #expect(failure?.contains(role.rawValue) == true)
            }
        }
    }

    @Test
    func absentAndUnknownRoleFieldsAreRejected() throws {
        for size in Qwen3ASRModelSize.allCases {
            for role in Qwen3ASRModelFileRole.allCases {
                var absentRoleManifest = manifestObject()
                var absentRoleFiles = fileRecords(for: size, in: absentRoleManifest)
                let absentIndex = absentRoleFiles.firstIndex { ($0["role"] as? String) == role.rawValue }!
                absentRoleFiles[absentIndex].removeValue(forKey: "role")
                setFileRecords(absentRoleFiles, for: size, in: &absentRoleManifest)
                #expect(decodeFailure(try encode(absentRoleManifest)) != nil)

                var unknownRoleManifest = manifestObject()
                var unknownRoleFiles = fileRecords(for: size, in: unknownRoleManifest)
                let unknownIndex = unknownRoleFiles.firstIndex { ($0["role"] as? String) == role.rawValue }!
                unknownRoleFiles[unknownIndex]["role"] = "unknown_role"
                setFileRecords(unknownRoleFiles, for: size, in: &unknownRoleManifest)
                #expect(decodeFailure(try encode(unknownRoleManifest)) != nil)
            }
        }
    }

    private func manifestObject() -> [String: Any] {
        Dictionary(uniqueKeysWithValues: Qwen3ASRModelSize.allCases.map { size in
            let files = size.files.map { file in
                [
                    "name": file.name,
                    "role": file.role.rawValue,
                    "byteCount": file.byteCount,
                    "sha256": file.sha256,
                ] as [String: Any]
            }
            return (
                size.rawValue,
                [
                    "hiddenSize": size.hiddenSize,
                    "repository": size.repository,
                    "commit": size.commit,
                    "files": files,
                ] as [String: Any]
            )
        })
    }

    private func encode(_ manifest: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    }

    private func fileRecords(for size: Qwen3ASRModelSize, in manifest: [String: Any]) -> [[String: Any]] {
        let entry = manifest[size.rawValue]! as! [String: Any]
        return entry["files"] as! [[String: Any]]
    }

    private func setFileRecords(
        _ files: [[String: Any]],
        for size: Qwen3ASRModelSize,
        in manifest: inout [String: Any]
    ) {
        var entry = manifest[size.rawValue]! as! [String: Any]
        entry["files"] = files
        manifest[size.rawValue] = entry
    }

    private func decodeFailure(_ data: Data) -> String? {
        do {
            _ = try Qwen3ASRModelSize.decodeManifests(data)
            return nil
        } catch {
            return String(describing: error)
        }
    }
}
