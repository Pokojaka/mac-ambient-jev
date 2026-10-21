import Foundation
import MacAmbientJevCore
import Testing
@testable import MacAmbientJevPortableRuntime

struct SileroVADModelTests {
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
        #expect(actual == FileSHA256.hexDigest(of: data))
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
