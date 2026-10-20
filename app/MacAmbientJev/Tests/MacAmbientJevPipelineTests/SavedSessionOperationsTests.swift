import Foundation
import Testing
import MacAmbientJevCore
@testable import MacAmbientJevPipeline

@Test
func savedSessionSelectionRejectsRecordingAndCanBeCleared() {
    var operations = SavedSessionOperations()
    let selectedURL = URL(fileURLWithPath: "/sessions/selected")
    let rejectedURL = URL(fileURLWithPath: "/sessions/rejected")

    let didSelectWhileIdle = operations.select(sessionURL: selectedURL, isRecording: false)
    #expect(didSelectWhileIdle)
    let didSelectWhileRecording = operations.select(sessionURL: rejectedURL, isRecording: true)
    #expect(!didSelectWhileRecording)
    #expect(operations.selectedSessionURL == selectedURL)

    operations.clearSelection()
    #expect(operations.selectedSessionURL == nil)
}

@Test
func readableSessionRequiresOneReadableSummary() {
    var operations = SavedSessionOperations()
    let session = makeSavedSession()

    operations.replaceSessions([.readable(session)])
    let uniqueMatch = operations.readableSession(session.sessionID)
    #expect(uniqueMatch == session)

    let unreadableSummary = SavedSessionSummary.unreadable(
        sessionURL: URL(fileURLWithPath: "/sessions/unreadable"),
        sessionID: session.sessionID,
        reason: "unreadable"
    )
    operations.replaceSessions([.readable(session), unreadableSummary])
    let duplicateMatch = operations.readableSession(session.sessionID)
    #expect(duplicateMatch == nil)

    operations.replaceSessions([unreadableSummary])
    let unreadableMatch = operations.readableSession(session.sessionID)
    #expect(unreadableMatch == nil)
}

@Test
func exportRejectsDuplicateStartAndRecordsCompletion() {
    var operations = SavedSessionOperations()
    let session = makeSavedSession()
    let folder = URL(fileURLWithPath: "/exports/session")

    let firstStart = operations.beginExport(session, isMaintainingStorage: false)
    #expect(firstStart == .ready)
    let duplicateStart = operations.beginExport(session, isMaintainingStorage: false)
    #expect(duplicateStart == .alreadyExporting)

    operations.completeExport(sessionID: session.sessionID, folder: folder)
    #expect(operations.exports[session.sessionID] == .exported(folder))
}

@Test
func failedExportCanBeRetried() {
    var operations = SavedSessionOperations()
    let session = makeSavedSession()

    let firstStart = operations.beginExport(session, isMaintainingStorage: false)
    #expect(firstStart == .ready)
    operations.failExport(sessionID: session.sessionID, message: "export failed")
    #expect(operations.exports[session.sessionID] == .failed("export failed"))

    let retryStart = operations.beginExport(session, isMaintainingStorage: false)
    #expect(retryStart == .ready)
    #expect(operations.exports[session.sessionID] == .exporting)
}

@Test
func existingExportProbeDoesNotOverwriteCurrentState() {
    var operations = SavedSessionOperations()
    let session = makeSavedSession()
    let folder = URL(fileURLWithPath: "/exports/session")

    let start = operations.beginExport(session, isMaintainingStorage: false)
    #expect(start == .ready)
    operations.recordExistingExport(.exported(folder), sessionID: session.sessionID)
    #expect(operations.exports[session.sessionID] == .exporting)
}

@Test
func resettingExportDestinationClearsExportStates() {
    var operations = SavedSessionOperations()
    let session = makeSavedSession()

    let start = operations.beginExport(session, isMaintainingStorage: false)
    #expect(start == .ready)
    operations.failExport(sessionID: session.sessionID, message: "export failed")
    operations.resetExportDestination()

    #expect(operations.exports.isEmpty)
}

private func makeSavedSession(sessionID: UUID = UUID()) -> SavedSession {
    SavedSession(
        sessionID: sessionID,
        sessionURL: URL(fileURLWithPath: "/sessions/\(sessionID.uuidString)"),
        createdAt: Date(timeIntervalSince1970: 0),
        source: .recording(.microphone),
        duration: .unknown,
        audio: .missing,
        hasActiveTranscript: false,
        processingStatus: .notProcessed
    )
}
