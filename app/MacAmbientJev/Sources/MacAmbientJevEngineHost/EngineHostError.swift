import Foundation
import MacAmbientJevEngineProtocol
import MacAmbientJevCore
import MacAmbientJevPipeline

public enum EngineHostError: LocalizedError {
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Engine host is not implemented."
        }
    }
}
