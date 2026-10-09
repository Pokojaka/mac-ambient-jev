import Darwin
import Foundation
import MacAmbientJevCore
import MacAmbientJevRuntime
import MLX

struct EngineMetrics: Codable {
    let runID: String
    let disposition: BatchDisposition
    let asr: ASRBatchMetrics?
    let message: String?
}

enum RunMonitorError: LocalizedError, Equatable {
    case duplicateDestination
    case destinationExists(String)
    case samplingFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .duplicateDestination:
            "計測ファイルの出力先が重複しています"
        case .destinationExists(let path):
            "計測ファイルが既に存在します: \(path)"
        case .samplingFailed(let path, let reason):
            "計測サンプルを書き込めませんでした: \(path): \(reason)"
        }
    }
}

/// Samples thermal state and memory into JSONL files during a measured run.
/// The first sample that cannot be written stops sampling and fails `write(_:)`.
actor RunMonitor {
    let runID: String
    let metricsURL: URL
    let thermalURL: URL
    let memoryURL: URL
    private var phase: RunPhase = .preparing
    private var samplingFailure: RunMonitorError?

    init(runID: String, metricsURL: URL, thermalURL: URL, memoryURL: URL) throws {
        let destinations = [metricsURL, thermalURL, memoryURL].map { url in
            let normalized = url.standardizedFileURL
            return normalized.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(normalized.lastPathComponent).standardizedFileURL
        }
        guard Set(destinations).count == destinations.count else {
            throw RunMonitorError.duplicateDestination
        }
        for url in [metricsURL, thermalURL, memoryURL] {
            try SessionFileAccess.createDirectory(url.deletingLastPathComponent(), relativeTo: url.deletingLastPathComponent())
            guard try SessionFileAccess.isDirectoryIfPresent(url, relativeTo: url.deletingLastPathComponent()) == nil else {
                throw RunMonitorError.destinationExists(url.path)
            }
        }
        self.runID = runID
        self.metricsURL = metricsURL
        self.thermalURL = thermalURL
        self.memoryURL = memoryURL
    }

    func setPhase(_ phase: RunPhase) async {
        self.phase = phase
        sample()
    }

    func shouldPause() -> Bool {
        ProcessInfo.processInfo.thermalState == .critical
    }

    func run() async {
        sample()
        while !Task.isCancelled, samplingFailure == nil {
            do { try await Task.sleep(for: .seconds(5)) } catch { break }
            sample()
        }
        sample()
    }

    func write(_ result: SessionProcessingResult) throws {
        let data = try JSONEncoder().encode(EngineMetrics(
            runID: runID, disposition: result.disposition,
            asr: result.metrics, message: result.message
        ))
        try SessionFileAccess.writeAtomically(data, to: metricsURL, relativeTo: metricsURL.deletingLastPathComponent())
        if let samplingFailure { throw samplingFailure }
    }

    private func sample() {
        guard samplingFailure == nil else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let thermal: [String: Any] = [
            "run_id": runID, "timestamp": timestamp,
            "state": String(describing: ProcessInfo.processInfo.thermalState)
        ]
        guard append(thermal, to: thermalURL) else { return }
        let mlx = Memory.snapshot()
        var memory: [String: Any] = [
            "run_id": runID, "timestamp": timestamp, "phase": phase.rawValue,
            "mlx_active_bytes": mlx.activeMemory,
            "mlx_cache_bytes": mlx.cacheMemory,
            "mlx_peak_bytes": mlx.peakMemory,
            "mlx_cache_limit_bytes": Memory.cacheLimit
        ]
        switch Self.footprint() {
        case .success(let bytes):
            memory["footprint_bytes"] = bytes
        case .failure(let error):
            memory["footprint_bytes"] = NSNull()
            memory["footprint_error"] = error.description
        }
        append(memory, to: memoryURL)
    }

    /// Appends one JSONL line; on failure records it as the run's sampling failure and returns false.
    @discardableResult
    private func append(_ value: [String: Any], to url: URL) -> Bool {
        do {
            try Self.appendLine(value, to: url)
            return true
        } catch {
            samplingFailure = .samplingFailed(path: url.path, reason: error.localizedDescription)
            return false
        }
    }

    private static func footprint() -> Result<UInt64, TaskInfoError> {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return .failure(TaskInfoError(code: result)) }
        return .success(info.phys_footprint)
    }

    private static func appendLine(_ value: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(0x0A)
        let handle = try SessionFileAccess.openHandle(url, relativeTo: url.deletingLastPathComponent(), writable: true, create: true)
        defer { try? handle.close() }
        let written = Result {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
        try handle.close()
        try written.get()
    }
}

/// A failed `task_info` call, described by its `kern_return_t`.
struct TaskInfoError: Error, CustomStringConvertible {
    let code: kern_return_t

    var description: String {
        "task_info kern_return_t \(code): \(String(cString: mach_error_string(code)))"
    }
}
