import Foundation
import MacAmbientJevEngineProtocol

@MainActor
final class EnginePageNavigation {
    private(set) var limit: Int

    struct Location {
        let token: String
        let start: Int
        let previousCursor: String?
    }

    private var firstLocation: Location
    private var locationsByToken: [String: Location] = [:]
    private var nextLocationsByToken: [String: Location] = [:]

    init(limit: Int) {
        self.limit = limit
        let firstLocation = Location(token: UUID().uuidString, start: 0, previousCursor: nil)
        self.firstLocation = firstLocation
        locationsByToken[firstLocation.token] = firstLocation
    }

    /// A nil cursor starts fresh navigation for the supplied limit; only a non-nil cursor must match the current navigation's limit.
    func location(cursor: String?, limit: Int) throws -> Location {
        guard let cursor else {
            self.limit = limit
            let firstLocation = Location(token: UUID().uuidString, start: 0, previousCursor: nil)
            self.firstLocation = firstLocation
            locationsByToken = [firstLocation.token: firstLocation]
            nextLocationsByToken = [:]
            return firstLocation
        }
        guard limit == self.limit else {
            throw EngineFailures.commandError(
                .invalidCursor, "limit がスナップショット作成時と一致しません", stage: .protocolValidation
            )
        }
        guard let location = locationsByToken[cursor] else {
            throw EngineFailures.commandError(.invalidCursor, "cursor が不正です", stage: .protocolValidation)
        }
        return location
    }

    func cursors(for location: Location, end: Int, total: Int) -> (next: String?, previous: String?) {
        let previous = location.previousCursor
        guard end < total else { return (nil, previous) }

        let nextLocation: Location
        if let existing = nextLocationsByToken[location.token] {
            nextLocation = existing
        } else {
            let next = Location(token: UUID().uuidString, start: end, previousCursor: location.token)
            locationsByToken[next.token] = next
            nextLocationsByToken[location.token] = next
            nextLocation = next
        }
        return (nextLocation.token, previous)
    }
}

@MainActor
struct EngineSessionListSnapshot {
    let sessions: [EngineSessionSummary]
    let navigation: EnginePageNavigation
    let pageSizer: EngineSessionListPageSizer

    init(sessions: [EngineSessionSummary], navigation: EnginePageNavigation) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        self.sessions = sessions
        self.navigation = navigation
        self.pageSizer = try EngineSessionListPageSizer(
            sessions: sessions,
            encodeSummary: { try encoder.encode($0) }
        )
    }
}
