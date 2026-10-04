import MacAmbientJevCore

/// Core tests feed 16-kHz mono blocks; Core itself has no sample-rate converter.
struct CanonicalMonoPassthrough: CanonicalAudioConverting {
    let sourceSampleRate = CanonicalAudio.sampleRate
    func convert(mono: [Float]) throws -> [Float] { mono }
    func finish() throws -> [Float] { [] }
}
