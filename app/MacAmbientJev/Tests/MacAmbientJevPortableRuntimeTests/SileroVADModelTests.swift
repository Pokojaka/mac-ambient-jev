import Foundation
import Testing
@testable import MacAmbientJevPortableRuntime

struct SileroVADModelTests {
    @Test
    func sha256DigestMatchesStandardVectorsAndPaddingBoundaries() {
        #expect(SileroVADModel.sha256Digest(Data())
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SileroVADModel.sha256Digest(Data("abc".utf8))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SileroVADModel.sha256Digest(Data(repeating: 0x61, count: 55))
            == "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
        #expect(SileroVADModel.sha256Digest(Data(repeating: 0x61, count: 56))
            == "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
        #expect(SileroVADModel.sha256Digest(Data(repeating: 0x61, count: 64))
            == "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
        #expect(SileroVADModel.sha256Digest(Data(repeating: 0x61, count: 1_000))
            == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    @Test
    func validationReportsPinnedHashMismatch() throws {
        let data = Data("not the pinned Silero model".utf8)
        let modelURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: modelURL) }
        try data.write(to: modelURL)

        var validationError: SileroVADModelValidationError?
        do {
            try SileroVADModel.validate(at: modelURL)
            Issue.record("Expected Silero model validation to reject the file.")
        } catch let error as SileroVADModelValidationError {
            validationError = error
        } catch {
            Issue.record("Unexpected validation error: \(error)")
        }

        guard let validationError else { return }
        guard case let .hashMismatch(expected, actual) = validationError else {
            Issue.record("Expected a SHA-256 mismatch, got: \(validationError)")
            return
        }
        #expect(expected == SileroVADModel.sha256)
        #expect(actual == SileroVADModel.sha256Digest(data))
        #expect(validationError.localizedDescription.contains("Silero"))
        #expect(validationError.localizedDescription.contains("SHA-256"))
        #expect(validationError.localizedDescription.contains(expected))
        #expect(validationError.localizedDescription.contains(actual))
    }

    @Test
    func validationReportsUnreadableMissingFile() {
        let modelURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        var validationError: SileroVADModelValidationError?
        do {
            try SileroVADModel.validate(at: modelURL)
            Issue.record("Expected validation to reject a missing model file.")
        } catch let error as SileroVADModelValidationError {
            validationError = error
        } catch {
            Issue.record("Unexpected validation error: \(error)")
        }

        guard let validationError else { return }
        guard case let .unreadable(path, _) = validationError else {
            Issue.record("Expected an unreadable-file error, got: \(validationError)")
            return
        }
        #expect(path == modelURL.path)
        #expect(validationError.localizedDescription.contains("Silero"))
        #expect(validationError.localizedDescription.contains("読み込めません"))
        #expect(validationError.localizedDescription.contains(modelURL.path))
    }
}
