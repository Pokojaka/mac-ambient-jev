import Foundation
import MacAmbientJevCore
@testable import MacAmbientJevRuntime
import Testing

@Test
func finalTranscriptVADProvenanceRecordsSegmentationConfiguration() throws {
    let paths = AppPaths(applicationSupportURL: URL(fileURLWithPath: "/tmp/unused-support"),
        cacheURL: URL(fileURLWithPath: "/tmp/unused-cache"), sessionsRootOverride: nil)
    let provenance = FluidFinalTranscriptVADSegmenter(models: try MacModelStore(paths: paths)).provenance
    #expect(provenance.engine == "fluidaudio-silero-vad")
    #expect(provenance.version == "FluidAudio@0.15.8")
    #expect(provenance.configuration == [
        "pre_roll_seconds": "0.1",
        "max_segment_seconds": "14.0",
        "min_silence_seconds": "0.75",
        "vad_threshold": "0.5",
        "split_search_window_seconds": "2.0",
        "split_energy_frame_seconds": "0.02",
        "minimum_independent_segment_seconds": "0.5",
    ])
}
