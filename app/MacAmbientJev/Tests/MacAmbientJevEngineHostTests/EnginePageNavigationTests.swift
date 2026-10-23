import Foundation
import Testing
@testable import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol

@MainActor
struct EnginePageNavigationTests {
    @Test func nilCursorStartsFreshNavigationBoundToIncomingLimit() throws {
        let navigation = EnginePageNavigation(limit: 3)
        let originalFirst = try navigation.location(cursor: nil, limit: 3)
        let originalCursors = navigation.cursors(for: originalFirst, end: 3, total: 9)
        let originalNextToken = try #require(originalCursors.next)
        let originalNext = try navigation.location(cursor: originalNextToken, limit: 3)
        #expect(originalNext.start == 3)
        #expect(originalNext.previousCursor == originalFirst.token)

        let freshFirst = try navigation.location(cursor: nil, limit: 2)
        #expect(navigation.limit == 2)
        #expect(freshFirst.start == 0)
        #expect(freshFirst.previousCursor == nil)
        #expect(freshFirst.token != originalFirst.token)
        let firstRoundTrip = try navigation.location(cursor: freshFirst.token, limit: 2)
        #expect(firstRoundTrip.token == freshFirst.token)
        #expect(firstRoundTrip.start == 0)

        for oldToken in [originalFirst.token, originalNextToken] {
            do {
                _ = try navigation.location(cursor: oldToken, limit: 2)
                Issue.record("old navigation token should be invalid after a first-page reset")
            } catch let error as EngineCommandError {
                #expect(error.code == .invalidCursor)
            }
        }

        let freshCursors = navigation.cursors(for: freshFirst, end: 2, total: 9)
        let freshNextToken = try #require(freshCursors.next)
        let freshNext = try navigation.location(cursor: freshNextToken, limit: 2)
        #expect(freshNext.start == 2)
        #expect(freshNext.previousCursor == freshFirst.token)

        do {
            _ = try navigation.location(cursor: freshNextToken, limit: 3)
            Issue.record("a known continuation token should reject a mismatched limit")
        } catch let error as EngineCommandError {
            #expect(error.code == .invalidCursor)
        }
        let correctLimitNext = try navigation.location(cursor: freshNextToken, limit: 2)
        #expect(correctLimitNext.token == freshNextToken)
        #expect(correctLimitNext.start == 2)
        #expect(correctLimitNext.previousCursor == freshFirst.token)
    }

    @Test func nilCursorResetsNavigationEvenWhenLimitIsUnchanged() throws {
        let navigation = EnginePageNavigation(limit: 3)
        let originalFirst = try navigation.location(cursor: nil, limit: 3)
        let originalNextToken = try #require(navigation.cursors(for: originalFirst, end: 3, total: 9).next)

        let freshFirst = try navigation.location(cursor: nil, limit: 3)
        #expect(freshFirst.token != originalFirst.token)
        #expect(freshFirst.start == 0)
        #expect(freshFirst.previousCursor == nil)

        do {
            _ = try navigation.location(cursor: originalNextToken, limit: 3)
            Issue.record("old continuation token should be invalid after a same-limit first-page reset")
        } catch let error as EngineCommandError {
            #expect(error.code == .invalidCursor)
        }
    }
}
