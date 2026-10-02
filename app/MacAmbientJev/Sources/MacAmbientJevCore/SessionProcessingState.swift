import Foundation

public enum ProcessingState: Sendable, Equatable {
    case idle
    case running
    case backlogged
    case complete
    case partialFailure(String)
}
