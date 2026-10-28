public enum ASRModelSize: String, CaseIterable, Sendable, Equatable {
    case small = "0.6b"
    case large = "1.7b"
}

public enum ASRExecutionProvider: String, CaseIterable, Hashable, Sendable, Equatable {
    case cpu, nvTensorRtRtx, openVINO, miGraphX, vitisAI, qnn
}

public struct ASRProfile: Sendable, Equatable {
    public let modelSize: ASRModelSize
    public let executionProvider: ASRExecutionProvider

    public init(modelSize: ASRModelSize, executionProvider: ASRExecutionProvider) {
        self.modelSize = modelSize
        self.executionProvider = executionProvider
    }
}

public enum ASRHardware: Sendable, Equatable {
    case noGPU
    case queryFailed(String)
    case gpu(name: String, adapterID: String, deviceID: String, driverVersion: String, dedicatedVRAMBytes: UInt64?)
}

public enum ASRAcquisition: Sendable, Equatable {
    case unavailable, failed(String), acquired(ASRExecutionProvider)
}

public enum ASRMemoryEnvelope: Sendable, Equatable {
    case unmeasured
    case measured(requiredDedicatedVRAMBytes: UInt64, requiredRAMBytes: UInt64, availableRAMBytes: UInt64)
}

public enum ASRVerification: Sendable, Equatable {
    case unverified, failed(String), verified
}
