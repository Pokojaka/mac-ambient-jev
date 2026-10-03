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
        guard SavedSessionSelectionPolicy.canSelect(
            isRecording: recordingPhase != .idle
        ) else {
            return
        }
        selectedSavedSessionID = sessionID
        displayedSessionID = sessionID
        transcriptViewModel.update(segments: [])
        transcriptViewModel.setDisplayState(.empty)
        transcriptViewModel.setStatus("保存済みの文字起こしを読み込んでいます")

        guard let audioSource = savedSessions
            .first(where: { $0.sessionID == sessionID })?.audioSource else {
            transcriptViewModel.setStatus("保存済み音声を使えないため、文字起こしを表示できません")
            return
        }
        do {
            switch try SavedTranscriptLoader.load(
                sessionURL: SessionLayout(sessionsRoot: paths.sessionsRoot, sessionID: sessionID).sessionURL,
                audioSource: audioSource
            ) {
            case .unavailable:
                transcriptViewModel.setStatus("この録音には確定文字起こしがありません")
            case .segments(let segments):
                transcriptViewModel.update(segments: segments)
                transcriptViewModel.setDisplayState(.finalized)
                transcriptViewModel.setStatus(
                    segments.isEmpty ? "確定文字起こしはありません" : "保存済み文字起こしを表示中"
                )
                Task { await probeExistingExport(sessionID: sessionID) }
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

    func exportSavedSession(sessionID: UUID) async {
        guard exportDirectoryPath != nil || chooseExportDirectory(),
              let session = readableSavedSession(sessionID) else {
            return
        }
        await export(session)
    }

    func readableSavedSession(_ sessionID: UUID) -> SavedSession? {
        guard case .readable(let session) = savedSessions.first(where: { $0.sessionID == sessionID }) else {
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
        sessionExports[session.sessionID] = .exporting
        let sessionsRoot = paths.sessionsRoot
        do {
            let folder = try await exportDestination.withAccess { directory in
                try await Task.detached {
                    try SessionExporter().export(
                        session: session,
                        sessionsRoot: sessionsRoot,
                        to: directory,
                        timeZone: .current
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
        let folderName = SessionExportLayout.folderName(for: session, timeZone: .current)
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
