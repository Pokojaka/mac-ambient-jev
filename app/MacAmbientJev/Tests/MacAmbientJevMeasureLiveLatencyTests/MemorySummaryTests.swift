import Testing
@testable import MacAmbientJevMeasureLiveLatency

@Test
func memorySummaryUsesRecordingWindowsAndAllSamplesForPeak() {
    let samples = [
        MemorySample(elapsed_seconds: 0, phase: "recording", footprint_bytes: 10),
        MemorySample(elapsed_seconds: 200, phase: "recording", footprint_bytes: 30),
        MemorySample(elapsed_seconds: 400, phase: "recording", footprint_bytes: 50),
        MemorySample(elapsed_seconds: 600, phase: "recording", footprint_bytes: 70),
        MemorySample(elapsed_seconds: 600, phase: "stopping", footprint_bytes: 100)
    ]
    let summary = MemorySummary(samples: samples, stopSeconds: 600)
    #expect(summary.firstMedian == 20)
    #expect(summary.lastMedian == 60)
    #expect(summary.peak == 100)
    #expect(summary.count == 5)
}
