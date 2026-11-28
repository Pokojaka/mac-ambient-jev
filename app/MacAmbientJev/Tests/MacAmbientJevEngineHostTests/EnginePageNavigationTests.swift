import Foundation
import Testing
@testable import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol

@MainActor
struct EnginePageNavigationTests {
    @Test func aFirstPageGetsNavigationBoundToItsIncomingLimit() throws {
        let installed = EnginePageNavigation(limit: 3)
        let installedFirst = try installed.location(cursor: nil, limit: 3)
        let installedNextToken = try #require(installed.cursors(for: installedFirst, end: 3, total: 9).next)
        #expect(try installed.location(cursor: installedNextToken, limit: 3).start == 3)

        let fresh = EnginePageNavigation(limit: 2)
        let freshFirst = try fresh.location(cursor: nil, limit: 2)
        #expect(fresh.limit == 2)
        #expect(freshFirst.start == 0)
        #expect(freshFirst.previousCursor == nil)
        #expect(freshFirst.token != installedFirst.token)
        for oldToken in [installedFirst.token, installedNextToken] {
            do {
                _ = try fresh.location(cursor: oldToken, limit: 2)
                Issue.record("a fresh navigation must reject tokens from the installed navigation")
            } catch let error as EngineCommandError {
                #expect(error.code == .invalidCursor)
            }
        }

        let freshNextToken = try #require(fresh.cursors(for: freshFirst, end: 2, total: 9).next)
        #expect(try fresh.location(cursor: freshNextToken, limit: 2).start == 2)
        do {
            _ = try fresh.location(cursor: freshNextToken, limit: 3)
            Issue.record("a known continuation token should reject a mismatched limit")
        } catch let error as EngineCommandError {
            #expect(error.code == .invalidCursor)
        }
        #expect(try installed.location(cursor: installedNextToken, limit: 3).start == 3)
    }

    @Test func nilCursorDoesNotMutateInstalledNavigation() throws {
        let navigation = EnginePageNavigation(limit: 3)
        let first = try navigation.location(cursor: nil, limit: 3)
        let nextToken = try #require(navigation.cursors(for: first, end: 3, total: 9).next)

        let firstAgain = try navigation.location(cursor: nil, limit: 2)
        #expect(navigation.limit == 3)
        #expect(firstAgain.token == first.token)
        #expect(try navigation.location(cursor: nextToken, limit: 3).start == 3)
    }
}
