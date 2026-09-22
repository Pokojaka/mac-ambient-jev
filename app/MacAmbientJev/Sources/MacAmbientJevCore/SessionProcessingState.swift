import Foundation

public enum CaptureState: Sendable, Equatable {
    case idle
    case recording
    case stopped
    case failed(String)
}

public enum ProcessingState: Sendable, Equatable {
    case idle
    case running
    case backlogged
    case complete
    case partialFailure(String)
}

public actor SessionProcessingState {
    public private(set) var captureState: CaptureState
    public private(set) var processingState: ProcessingState

    public init(
        captureState: CaptureState = .idle,
        processingState: ProcessingState = .idle
    ) {
        self.captureState = captureState
        self.processingState = processingState
    }

    public func setCapture(_ state: CaptureState) {
        captureState = state
    }

    public func setProcessing(_ state: ProcessingState) {
        processingState = state
    }
}
