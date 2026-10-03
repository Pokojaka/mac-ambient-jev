import Foundation

public enum LiveTranscriptionCadence {
    public static let durableChunkDurationSeconds = 0.5
    public static let checkpointPollIntervalMilliseconds = 250
    /// How often suspended live recognition re-reads the thermal state to resume once it drops below critical.
    public static let thermalRecheckIntervalMilliseconds = 1_000
}
