import Foundation

public enum SpeechFixtures {
    public static func wavURL(named name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Resources") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }
}
