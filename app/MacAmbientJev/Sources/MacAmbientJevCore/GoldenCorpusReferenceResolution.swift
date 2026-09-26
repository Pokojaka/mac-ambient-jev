import Foundation

public extension GoldenCorpusReference {
    func resolvedText(
        relativeTo manifestURL: URL
    ) throws -> String? {
        if let text {
            return text
        }
        guard let path else {
            return nil
        }

        let referenceURL: URL
        if path.hasPrefix("/") {
            referenceURL = URL(fileURLWithPath: path)
        } else {
            referenceURL = manifestURL
                .deletingLastPathComponent()
                .appending(path: path)
        }

        return try String(
            contentsOf: referenceURL.standardizedFileURL,
            encoding: .utf8
        )
    }
}
