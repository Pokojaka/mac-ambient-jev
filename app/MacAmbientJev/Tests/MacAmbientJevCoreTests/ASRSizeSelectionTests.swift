import Testing
import MacAmbientJevCore

@Suite
struct ASRSizeSelectionTests {
    private let memory = ASRMemoryEnvelope.measured(
        requiredDedicatedVRAMBytes: 8, requiredRAMBytes: 16, availableRAMBytes: 16
    )
    // Synthetic policy fixture only; this ratio is not production calibration.
    private let calibration = ASRRatioCalibration(
        id: "synthetic", executionProviders: [.openVINO], ratioUpperBound: 2
    )

    private func gpu(_ vram: UInt64?) -> ASRHardware {
        .gpu(name: "opaque GPU", adapterID: "adapter", deviceID: "device", driverVersion: "driver", dedicatedVRAMBytes: vram)
    }
    private func gate(_ hardware: ASRHardware, _ acquisition: ASRAcquisition, _ envelope: ASRMemoryEnvelope, _ assets: Bool) -> ASRInitialSizeGate {
        initialSizeGate(hardware: hardware, acquisition: acquisition, memoryEnvelope: envelope, assetsAvailable: assets)
    }

    @Test func rejectedHardwareOrProvider() throws {
        let rows: [(ASRHardware, ASRAcquisition, ASRMemoryEnvelope, ASRSizeSelectionReason)] = [
            (.noGPU, .acquired(.openVINO), memory, .noGPU),
            (.queryFailed("query"), .acquired(.openVINO), memory, .hardwareQueryFailed),
            (gpu(8), .unavailable, memory, .providerUnavailable),
            (gpu(8), .failed("acquire"), memory, .providerAcquisitionFailed),
            (gpu(7), .acquired(.openVINO), memory, .insufficientDedicatedVRAM),
            (gpu(0), .acquired(.openVINO), .unmeasured, .insufficientDedicatedVRAM),
            (gpu(nil), .acquired(.openVINO), memory, .unknownDedicatedVRAM),
            (gpu(8), .acquired(.openVINO), .measured(requiredDedicatedVRAMBytes: 8, requiredRAMBytes: 16, availableRAMBytes: 0), .insufficientMemory)
        ]
        for (hardware, acquisition, envelope, reason) in rows {
            let initial = gate(hardware, acquisition, envelope, true).selection
            #expect(initial.reason == reason && initial.size == .small && !initial.recommendLarge)
            #expect(!initial.explanation.isEmpty && initial.measuredRTF == nil && initial.predictedRTF == nil)
            let result = try recommendLarge(gate: gate(hardware, acquisition, envelope, true), verification: .verified, measuredRTF: 0.1, calibration: calibration)
            #expect(result.reason == reason && !result.recommendLarge && result.predictedRTF == nil)
            #expect(result.measuredRTF == 0.1 && !result.explanation.contains("未計測"))
        }
        #expect(throws: ASRSelectionError.invalidMeasuredRTF) {
            _ = try recommendLarge(gate: gate(.noGPU, .unavailable, memory, true), verification: .verified, measuredRTF: 0, calibration: calibration)
        }
    }

    @Test func awaitingAssets() throws {
        let initial = gate(gpu(8), .acquired(.openVINO), memory, false).selection
        #expect(initial.reason == .awaitingAssets && !initial.recommendLarge && initial.measuredRTF == nil && initial.predictedRTF == nil)
        let result = try recommendLarge(gate: gate(gpu(8), .acquired(.openVINO), memory, false), verification: .verified, measuredRTF: 0.1, calibration: calibration)
        #expect(result.reason == .awaitingAssets && !result.recommendLarge && result.predictedRTF == nil)
        let unmeasured = gate(gpu(8), .acquired(.openVINO), .unmeasured, false).selection
        #expect(unmeasured.reason == .awaitingAssets && unmeasured.measuredRTF == nil && unmeasured.predictedRTF == nil)
    }

    @Test func verificationFailure() throws {
        let result = try recommendLarge(gate: gate(gpu(8), .acquired(.openVINO), memory, true), verification: .failed("probe"), measuredRTF: 0.2, calibration: calibration)
        #expect(result.reason == .verificationFailed && !result.recommendLarge && result.predictedRTF == nil)
        #expect(result.explanation == "EP の検証に失敗しました。CPU を使用する場合は選択してください")
        let noGPU = try recommendLarge(gate: gate(.noGPU, .unavailable, memory, true), verification: .failed("probe"), measuredRTF: 0.2, calibration: calibration)
        #expect(noGPU.reason == .verificationFailed)
    }

    @Test func missingCalibration() throws {
        let eligible = gate(gpu(8), .acquired(.openVINO), memory, true)
        let cpuOnly = ASRRatioCalibration(id: "synthetic-cpu", executionProviders: [.cpu], ratioUpperBound: 2)
        for calibration in [Optional<ASRRatioCalibration>.none, cpuOnly] {
            let result = try recommendLarge(gate: eligible, verification: .verified, measuredRTF: 0.2, calibration: calibration)
            #expect(result.reason == .uncalibrated && result.measuredRTF == 0.2 && result.predictedRTF == nil)
        }
        let unmeasured = gate(gpu(8), .acquired(.openVINO), .unmeasured, true)
        #expect(unmeasured.selection.reason == .uncalibrated)
        let result = try recommendLarge(gate: unmeasured, verification: .verified, measuredRTF: 0.2, calibration: calibration)
        #expect(result.reason == .uncalibrated && !result.recommendLarge && result.predictedRTF == nil)
    }

    @Test func recommendsLargeAtBoundary() throws {
        for measured in [0.35, 0.34] {
            let result = try recommendLarge(gate: gate(gpu(8), .acquired(.openVINO), memory, true), verification: .verified, measuredRTF: measured, calibration: calibration)
            #expect(result.reason == .recommendLarge && result.recommendLarge && result.size == .small)
            #expect(result.measuredRTF == measured && !result.explanation.isEmpty)
        }
        let boundary = try recommendLarge(gate: gate(gpu(8), .acquired(.openVINO), memory, true), verification: .verified, measuredRTF: 0.35, calibration: calibration)
        #expect(boundary.predictedRTF == 0.70)
    }

    @Test func retainsSmallOtherwise() throws {
        let slow = try recommendLarge(gate: gate(gpu(8), .acquired(.openVINO), memory, true), verification: .verified, measuredRTF: 0.36, calibration: calibration)
        #expect(slow.reason == .tooSlow && slow.predictedRTF == 0.72 && !slow.recommendLarge && slow.size == .small)
        let unmeasured = try recommendLarge(gate: gate(gpu(8), .acquired(.openVINO), memory, true), verification: .verified, measuredRTF: nil, calibration: calibration)
        #expect(unmeasured.reason == .unmeasured && unmeasured.measuredRTF == nil && unmeasured.predictedRTF == nil)
        let unverified = try recommendLarge(gate: gate(gpu(8), .acquired(.openVINO), memory, true), verification: .unverified, measuredRTF: 0.1, calibration: calibration)
        #expect(unverified.reason == .verificationRequired && !unverified.recommendLarge && unverified.predictedRTF == nil)
    }

    @Test func invalidEvidenceFails() {
        let eligible = gate(gpu(8), .acquired(.openVINO), memory, true)
        let rejected = gate(.noGPU, .unavailable, memory, true)
        for measured in [0.0, -0.1, .nan, .infinity, -.infinity] {
            #expect(throws: ASRSelectionError.invalidMeasuredRTF) {
                _ = try recommendLarge(gate: eligible, verification: .verified, measuredRTF: measured, calibration: calibration)
            }
            #expect(throws: ASRSelectionError.invalidMeasuredRTF) {
                _ = try recommendLarge(gate: rejected, verification: .verified, measuredRTF: measured, calibration: calibration)
            }
        }
        let invalidCalibrations = [
            ASRRatioCalibration(id: "", executionProviders: [.openVINO], ratioUpperBound: 2),
            ASRRatioCalibration(id: "synthetic", executionProviders: [], ratioUpperBound: 2),
            ASRRatioCalibration(id: "synthetic", executionProviders: [.openVINO], ratioUpperBound: 0),
            ASRRatioCalibration(id: "synthetic", executionProviders: [.openVINO], ratioUpperBound: -1),
            ASRRatioCalibration(id: "synthetic", executionProviders: [.openVINO], ratioUpperBound: .nan),
            ASRRatioCalibration(id: "synthetic", executionProviders: [.openVINO], ratioUpperBound: .infinity)
        ]
        for invalid in invalidCalibrations {
            #expect(throws: ASRSelectionError.invalidCalibration) {
                _ = try recommendLarge(gate: eligible, verification: .verified, measuredRTF: 0.1, calibration: invalid)
            }
        }
        #expect(throws: ASRSelectionError.invalidPrediction) {
            _ = try recommendLarge(gate: eligible, verification: .verified, measuredRTF: .greatestFiniteMagnitude, calibration: calibration)
        }
    }
}
