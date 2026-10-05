import AppKit
import AVFoundation
import Combine
import Dispatch
import Foundation
import MacAmbientJevAppleSupport
import MacAmbientJevCore
import MacAmbientJevCapture
import MacAmbientJevRuntime
import UniformTypeIdentifiers

extension AppState {
    func refreshSavedSessions() {
        do {
            savedSessions = try SavedSessionCatalog(fileManager: .default).list(
                sessionsRoot: paths.sessionsRoot
            )
        } catch {
            processingStatusText = "保存済み録音を読み込めませんでした: \(error.localizedDescription)"
        }
    }

    func selectSavedSession(sessionID: UUID) {
        do {
            let sessionURL = try SessionDirectoryLocator(fileManager: .default)
                .resolve(sessionsRoot: paths.sessionsRoot, sessionID: sessionID)
            selectSavedSession(sessionURL: sessionURL)
        } catch {
            transcriptViewModel.setStatus("保存済み録音を選択できませんでした: \(error.localizedDescription)")
        }
    }

    func selectSavedSession(sessionURL: URL) {
        guard SavedSessionSelectionPolicy.canSelect(
            isRecording: recordingPhase != .idle
        ) else {
            return
        }
        selectedSavedSessionURL = sessionURL
        let summary = savedSessions.first(where: { $0.sessionURL == sessionURL })
        displayedSessionID = summary?.sessionID
        do {
            try transcriptViewModel.update(segments: [])
        } catch {
            transcriptViewModel.setStatus("文字起こし表示を初期化できませんでした: \(error.localizedDescription)")
            return
        }
        transcriptViewModel.setDisplayState(.empty)
        transcriptViewModel.setStatus("保存済みの文字起こしを読み込んでいます")

        guard case .readable(let session) = summary,
              let audioSource = session.audioSource else {
            transcriptViewModel.setStatus("保存済み音声を使えないため、文字起こしを表示できません")
            return
        }
        do {
            switch try SavedTranscriptLoader.load(
                sessionURL: sessionURL,
                audioSource: audioSource
            ) {
            case .unavailable:
                transcriptViewModel.setStatus("この録音には確定文字起こしがありません")
            case .segments(let segments):
                try transcriptViewModel.update(segments: segments)
                transcriptViewModel.setDisplayState(.finalized)
                transcriptViewModel.setStatus(
                    segments.isEmpty ? "確定文字起こしはありません" : "保存済み文字起こしを表示中"
                )
                Task { await probeExistingExport(sessionID: session.sessionID) }
            }
        } catch {
            transcriptViewModel.setStatus(
                "保存済み文字起こしを読み込めませんでした: \(error.localizedDescription)"
            )
        }
    }

    @discardableResult
    func chooseExportDirectory() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "書き出し先フォルダを選択"
        panel.prompt = "選択"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let directory = panel.url else {
            return false
        }
        do {
            try exportDestination.save(directory: directory)
            exportDirectoryPath = exportDestination.path
            exportDestinationMessage = nil
            sessionExports = [:]
            return true
        } catch {
            exportDestinationMessage = "書き出し先フォルダを保存できませんでした: \(error.localizedDescription)"
            return false
        }
    }

    func revealExportDirectory() async {
        do {
            try await exportDestination.withAccess { directory in
                NSWorkspace.shared.activateFileViewerSelecting([directory])
            }
            exportDestinationMessage = nil
        } catch {
            exportDestinationMessage = error.localizedDescription
        }
    }

    func revealSessionsRoot() {
        do {
            NSWorkspace.shared.activateFileViewerSelecting([try existingSessionsRoot()])
            exportDestinationMessage = nil
        } catch {
            exportDestinationMessage = error.localizedDescription
        }
    }

    func revealSessionFolder(sessionURL: URL) {
        do {
            NSWorkspace.shared.activateFileViewerSelecting([try existingSessionFolder(sessionURL)])
        } catch {
            processingStatusText = error.localizedDescription
        }
    }

    func existingSessionsRoot() throws -> URL {
        try Self.existingDirectory(paths.sessionsRoot, missing: .sessionsRootMissing)
    }

    func existingSessionFolder(_ sessionURL: URL) throws -> URL {
        guard let summary = savedSessions.first(where: { $0.sessionURL == sessionURL }) else {
            throw SessionFolderRevealError.notInCatalog(sessionURL.lastPathComponent)
        }
        return try Self.existingDirectory(
            summary.sessionURL,
            missing: .sessionFolderMissing(summary.sessionURL.lastPathComponent)
        )
    }

    private static func existingDirectory(_ url: URL, missing: SessionFolderRevealError) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw missing
        }
        return url
    }

    func exportSavedSession(sessionID: UUID) async {
        guard exportDirectoryPath != nil || chooseExportDirectory(),
              let session = readableSavedSession(sessionID) else {
            return
        }
        await export(session)
    }

    func readableSavedSession(_ sessionID: UUID) -> SavedSession? {
        let matches = savedSessions.filter { $0.sessionID == sessionID }
        guard matches.count == 1, case .readable(let session) = matches[0] else {
            return nil
        }
        return session
    }

    func revealExport(sessionID: UUID) async {
        guard case .exported(let folder) = sessionExports[sessionID] else { return }
        do {
            try await exportDestination.withAccess { _ in
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        } catch {
            sessionExports[sessionID] = .failed(error.localizedDescription)
        }
    }

    func autoExportIfEnabled(sessionID: UUID) async {
        guard exportDirectoryPath != nil else { return }
        do {
            guard try exportDestination.isAutoExportEnabled() else { return }
        } catch {
            exportDestinationMessage = error.localizedDescription
            processingStatusText = error.localizedDescription
            return
        }
        refreshSavedSessions()
        guard let session = readableSavedSession(sessionID), session.hasActiveTranscript else {
            return
        }
        switch session.processingStatus {
        case .complete, .classificationPending:
            await export(session)
        case .notProcessed, .running, .paused, .failed, .corrupted:
            break
        }
    }

    func export(_ session: SavedSession) async {
        guard sessionExports[session.sessionID] != .exporting else { return }
        if isMaintainingStorage, case .recordedPCM = session.audioSource {
            let message = "保存済み録音の音声を整理しています。整理が終わってから書き出してください"
            sessionExports[session.sessionID] = .failed(message)
            processingStatusText = "書き出せませんでした: \(message)"
            return
        }
        sessionExports[session.sessionID] = .exporting
        do {
            let folder = try await exportDestination.withAccess { directory in
                try await Task.detached {
                    try SessionExporter().export(
                        session: session,
                        to: directory
                    )
                }.value
            }
            sessionExports[session.sessionID] = .exported(folder)
            processingStatusText = "「\(folder.lastPathComponent)」に書き出しました"
        } catch {
            sessionExports[session.sessionID] = .failed(error.localizedDescription)
            processingStatusText = "書き出せませんでした: \(error.localizedDescription)"
        }
    }

    /// Marks the session exported only when its folder holds both `transcript.txt` and the audio file.
    func probeExistingExport(sessionID: UUID) async {
        guard sessionExports[sessionID] == nil,
              exportDirectoryPath != nil,
              let session = readableSavedSession(sessionID),
              let audioSource = session.audioSource else {
            return
        }
        let folderName = session.sessionURL.lastPathComponent
        let state: SessionExportState?
        do {
            let existing = try await exportDestination.withAccess { directory -> URL? in
                let folder = directory.appending(path: folderName, directoryHint: .isDirectory)
                return SessionExportLayout.isCompleteExport(folder: folder, audioSource: audioSource)
                    ? folder
                    : nil
            }
            state = existing.map(SessionExportState.exported)
        } catch {
            state = .failed("書き出し先を確認できません: \(error.localizedDescription)")
        }
        if let state, sessionExports[sessionID] == nil {
            sessionExports[sessionID] = state
        }
    }
}

enum SessionFolderRevealError: Error, LocalizedError, Equatable {
    case sessionsRootMissing
    case sessionFolderMissing(String)
    case notInCatalog(String)

    var errorDescription: String? {
        switch self {
        case .sessionsRootMissing:
            "録音データのフォルダがまだありません"
        case .sessionFolderMissing(let name):
            "録音データのフォルダ「\(name)」が見つかりません"
        case .notInCatalog(let name):
            "保存済み録音の一覧にないフォルダ「\(name)」は Finder で表示できません"
        }
    }
}
