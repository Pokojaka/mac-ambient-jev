import Foundation

public struct CaptureReconnectEndpoint: Sendable, Equatable {
    public let id: String
    public let isDefault: Bool

    public init(id: String, isDefault: Bool) {
        precondition(!id.isEmpty)
        self.id = id
        self.isDefault = isDefault
    }
}

public struct CaptureDeviceReconnect: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case capturing(endpointID: String)
        case waiting(endpointID: String, startedAt: TimeInterval, deadline: TimeInterval)
        case stopped
    }

    public enum Action: Sendable, Equatable {
        case none
        case reopen(endpointID: String)
        case deviceLost
    }

    public static let waitSeconds: TimeInterval = 30

    public private(set) var state: State
    private let followsDefaultOutput: Bool

    public init(endpointID: String, followsDefaultOutput: Bool) {
        precondition(!endpointID.isEmpty)
        self.state = .capturing(endpointID: endpointID)
        self.followsDefaultOutput = followsDefaultOutput
    }

    public mutating func deviceLost(now: TimeInterval) -> Bool {
        Self.validateClock(now)
        guard case .capturing(let endpointID) = state else { return false }

        let deadline = now + Self.waitSeconds
        precondition(deadline.isFinite)
        state = .waiting(endpointID: endpointID, startedAt: now, deadline: deadline)
        return true
    }

    public mutating func poll(now: TimeInterval, endpoints: [CaptureReconnectEndpoint]) -> Action {
        Self.validateClock(now)
        let endpointIDs = endpoints.map(\.id)
        precondition(Set(endpointIDs).count == endpointIDs.count)
        precondition(endpoints.filter(\.isDefault).count <= 1)

        guard case .waiting(let waitingEndpointID, let startedAt, let deadline) = state else {
            return .none
        }
        precondition(now >= startedAt)
        if now >= deadline {
            state = .stopped
            return .deviceLost
        }

        let eligibleEndpointID: String?
        if followsDefaultOutput {
            eligibleEndpointID = endpoints.first(where: \.isDefault)?.id
        } else {
            eligibleEndpointID = endpoints.first(where: { $0.id == waitingEndpointID })?.id
        }
        guard let eligibleEndpointID else { return .none }
        return .reopen(endpointID: eligibleEndpointID)
    }

    public mutating func didResume(endpointID: String, now: TimeInterval) -> Bool {
        precondition(!endpointID.isEmpty)
        Self.validateClock(now)
        guard case .waiting(let waitingEndpointID, let startedAt, let deadline) = state else {
            return false
        }
        precondition(now >= startedAt)
        if now >= deadline {
            state = .stopped
            return false
        }
        if !followsDefaultOutput {
            precondition(endpointID == waitingEndpointID)
        }
        state = .capturing(endpointID: endpointID)
        return true
    }

    public mutating func stop() {
        state = .stopped
    }

    private static func validateClock(_ now: TimeInterval) {
        precondition(now.isFinite && now >= 0)
    }
}
