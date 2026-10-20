/// Validates whether an end frame belongs to the audio or its final scheduled window.
/// The caller must validate that the start frame is nonnegative and in range and that the
/// duration is positive. A `nil` result explicitly rejects the geometry or end frame; it is
/// not a fallback signal.
public enum DiarizationFinalWindowPadding {
    public static func clampedEndFrame(
        _ endFrame: Int64,
        sampleCount: Int64,
        windowSamples: Int64,
        stepSamples: Int64
    ) -> Int64? {
        guard sampleCount >= 0,
              endFrame >= 0,
              windowSamples > 0,
              stepSamples > 0 else {
            return nil
        }

        guard sampleCount > 0 else {
            return endFrame == 0 ? 0 : nil
        }

        let availableFinalWindowSamples = ((sampleCount - 1) % stepSamples) + 1
        let paddingSamples = windowSamples > availableFinalWindowSamples
            ? windowSamples - availableFinalWindowSamples
            : 0

        guard endFrame > sampleCount else { return endFrame }
        guard endFrame - sampleCount <= paddingSamples else { return nil }
        return sampleCount
    }
}
