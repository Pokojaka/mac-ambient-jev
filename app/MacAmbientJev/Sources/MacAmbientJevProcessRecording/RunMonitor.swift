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

actor RunMonitor {
    let runID: String
    let metricsURL: URL
    let thermalURL: URL
    let memoryURL: URL
    private var phase: RunPhase = .preparing

    init(runID: String, metricsURL: URL, thermalURL: URL, memoryURL: URL) throws {
        let destinations = [metricsURL, thermalURL, memoryURL].map { url in
            let normalized = url.standardizedFileURL
            return normalized.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(normalized.lastPathComponent).standardizedFileURL
        }
        guard Set(destinations).count == destinations.count else {
            throw NSError(domain: "RunMonitor", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "計測ファイルの出力先が重複しています"
            ])
        }
        for url in [metricsURL, thermalURL, memoryURL] {
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw NSError(domain: "RunMonitor", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "計測ファイルが既に存在します: \(url.path)"
                ])
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        }
        self.runID = runID
        self.metricsURL = metricsURL
        self.thermalURL = thermalURL
        self.memoryURL = memoryURL
    }

    func setPhase(_ phase: RunPhase) async {
        self.phase = phase
        try? sample()
    }

    func shouldPause() -> Bool {
        ProcessInfo.processInfo.thermalState == .critical
    }

    func run() async {
        try? sample()
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(5)) } catch { break }
            try? sample()
        }
        try? sample()
    }

    func write(_ result: SessionProcessingResult) throws {
        let data = try JSONEncoder().encode(EngineMetrics(
            runID: runID, disposition: result.disposition,
            asr: result.metrics, message: result.message
        ))
        try data.write(to: metricsURL, options: .atomic)
    }

    private func sample() throws {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let thermal: [String: Any] = [
            "run_id": runID, "timestamp": timestamp,
            "state": String(describing: ProcessInfo.processInfo.thermalState)
        ]
        try append(thermal, to: thermalURL)
        let mlx = Memory.snapshot()
        let memory: [String: Any] = [
            "run_id": runID, "timestamp": timestamp, "phase": phase.rawValue,
            "footprint_bytes": footprint().map { $0 as Any } ?? NSNull(),
            "mlx_active_bytes": mlx.activeMemory,
            "mlx_cache_bytes": mlx.cacheMemory,
            "mlx_peak_bytes": mlx.peakMemory,
            "mlx_cache_limit_bytes": Memory.cacheLimit
        ]
        try append(memory, to: memoryURL)
    }

    private func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    private func append(_ value: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
