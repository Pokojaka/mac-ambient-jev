import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineProtocol

@MainActor
extension EngineApplicationCore {
    func bind(_ payload: EngineAcceleratorsBindPayload, context: EngineRequestContext) async throws -> EngineAcceleratorsBindResult {
        try acquireAcceleratorSetup(.binding)
        defer { finishAcceleratorSetup() }
        let bindingID = UUID().uuidString.lowercased()
        acceleratorBindings[bindingID] = payload.descriptor
        return try EngineAcceleratorsBindResult(bindingID: bindingID)
    }

    func verify(_ payload: EngineAcceleratorsVerifyPayload, context: EngineRequestContext) async throws -> EngineAcceleratorsVerifyResult {
        try acquireAcceleratorSetup(.verifying)
        defer { finishAcceleratorSetup() }
        guard payload.asrSize == .small else {
            throw EngineFailures.commandError(.invalidRequest, "検証は固定出力の 0.6B のみ対応しています", stage: .loadingModels)
        }
        guard logicalCPUCount > 0, payload.threads <= min(PortableThreadLimit.maximum, logicalCPUCount) else {
            throw EngineFailures.commandError(.invalidRequest, "スレッド数が論理 CPU 数の上限を超えています", stage: .loadingModels)
        }
        guard let descriptor = acceleratorBindings[payload.bindingID] else {
            throw EngineFailures.commandError(.invalidRequest, "アクセラレーターの binding が見つかりません", stage: .loadingModels)
        }
        let task = Task { @MainActor [self] in
            try await runAcceleratorVerification(descriptor: descriptor, threads: payload.threads)
        }
        acceleratorSetupTask = task
        do {
            return try await task.value
        } catch {
            if isAcceleratorCancellation(error) || Task.isCancelled || isShuttingDown {
                throw acceleratorCancellationError()
            }
            throw EngineFailures.commandError(from: error, fallback: .modelFailure, stage: .loadingModels)
        }
    }

    func decide(_ payload: EngineProfilesDecidePayload, context: EngineRequestContext) async throws -> EngineProfileEvaluation {
        guard !Task.isCancelled, !isShuttingDown else { throw acceleratorCancellationError() }
        guard isIdle else {
            throw EngineFailures.commandError(
                .busy, "録音または処理の実行中はプロファイル判定を変更できません", stage: .settings, recoveryAction: .retry
            )
        }
        let revision = currentState().revision
        guard payload.expectedRevision == revision else {
            throw EngineFailures.commandError(
                .staleRevision, "プロファイル判定の revision が古くなっています。状態を読み直してください", stage: .settings, recoveryAction: .retry
            )
        }
        guard let current = profileEvaluation else {
            throw EngineFailures.commandError(.invalidRequest, "profiles.evaluate を実行してください", stage: .settings)
        }
        let completes = payload.choice == .small || (settings?.asrSize == .large && inference != nil)
        let explanation = completes
            ? "\(payload.choice == .small ? "0.6B" : "1.7B") を選択しました。設定の適用には settings.replace と models.prepare を実行してください。"
            : "1.7B の準備・検証待ちです。導入手順を確認してください。アプリ内ダウンロードは未提供です"
        do {
            let evaluation = try EngineProfileEvaluation(
                initialSize: current.initialSize, recommendLarge: false,
                reason: completes ? .eligible : .awaitingAssets, explanation: explanation,
                measuredRTF: current.measuredRTF, predictedRTF: current.predictedRTF,
                decisionState: completes ? .complete : .awaitingAssets,
                requestedChoice: payload.choice, calibrationID: current.calibrationID
            )
            try profileDecisionStore.save(evaluation)
            profileEvaluation = evaluation
            stateDidChange()
            return evaluation
        } catch {
            throw profileDecisionCommandError(error)
        }
    }

    private func acquireAcceleratorSetup(_ operation: EngineProfileSetupOperation) throws {
        guard !Task.isCancelled, !isShuttingDown else { throw acceleratorCancellationError() }
        guard profileSetupOperation == nil, recording.phase == .idle, !isPreparingModels,
              !processingCoordinator.isDraining, processingQueue.currentSessionID == nil,
              processingQueue.claimedSessionIDs.isEmpty, liveCoordinator.isASRIdle else {
            throw EngineFailures.commandError(
                .busy, "録音・処理・準備の実行中はアクセラレーターを設定できません", stage: .loadingModels,
                recoveryAction: .retry
            )
        }
        profileSetupOperation = operation
        stateDidChange()
    }

    private func finishAcceleratorSetup() {
        profileSetupOperation = nil
        acceleratorSetupTask = nil
        guard !isShuttingDown else { return }
        stateDidChange()
        processingCoordinator.startDrainIfIdle()
    }

    private func runAcceleratorVerification(
        descriptor: EngineAcceleratorDescriptor,
        threads: Int
    ) async throws -> EngineAcceleratorsVerifyResult {
        try await acceleratorRegistry.registerLibrary(descriptor)
        try checkAcceleratorVerificationCanContinue()
        let device = try await acceleratorRegistry.selectDevice(
            providerName: descriptor.providerName, deviceID: descriptor.deviceID
        )
        try checkAcceleratorVerificationCanContinue()
        let ortVersion = device.ortVersion
        guard ortVersion == "1.31.0" else {
            throw EngineAdapterError(
                code: .modelFailure, message: "アクセラレーターの ONNX Runtime バージョンが検証要件と一致しません",
                recoveryAction: .none, details: []
            )
        }
        let modelRevision = device.modelRevision
        guard !modelRevision.isEmpty else {
            throw EngineAdapterError(
                code: .modelFailure, message: "アクセラレーターがモデル revision を返しませんでした",
                recoveryAction: .none, details: []
            )
        }
        let packageIdentity = [descriptor.providerName, descriptor.packageIdentity] + descriptor.dependencies.map(\.hash).sorted()
        let packageHash = FileSHA256.hexDigest(of: try JSONEncoder().encode(packageIdentity))
        let key = EngineVerificationKey(gpuName: descriptor.gpuName, driverVersion: descriptor.driverVersion,
            adapterID: descriptor.adapterID, deviceID: descriptor.deviceID,
            architecture: descriptor.architecture, epPackageHash: packageHash,
            epLibraryHash: descriptor.libraryHash, ortVersion: ortVersion,
            modelRevision: modelRevision, modelSize: EngineASRSize.small.rawValue,
            decodingSettings: EngineAcceleratorVerificationFixture.decodingSettings,
            fixtureHash: EngineAcceleratorVerificationFixture.fixtureHash,
            verificationPolicyVersion: EngineAcceleratorVerificationFixture.policyVersion, threads: threads
        )
        let engine = try await device.makeASREngine(
            size: .small, threads: threads, language: "ja", maxNewTokens: 448, noRepeatNgramSize: nil
        )
        let verification: (output: String, inferenceError: (any Error)?, rtf: Double)
        do {
            try await engine.prepare()
            let fixture = try EngineAcceleratorVerificationFixture.load()
            let clock = ContinuousClock()
            let started = clock.now
            var output = ""
            var failedInference: (any Error)?
            do {
                output = try await engine.transcribe(fixture).text
            } catch {
                if isAcceleratorCancellation(error) { throw CancellationError() }
                failedInference = error
            }
            let elapsed = started.duration(to: clock.now).components
            try checkAcceleratorVerificationCanContinue()
            let inferenceSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
            let audioSeconds = Double(fixture.samples.count) / Double(fixture.sampleRate)
            let measuredRTF = inferenceSeconds / audioSeconds
            guard measuredRTF.isFinite, measuredRTF > 0 else {
                throw EngineAdapterError(
                    code: .modelFailure, message: "アクセラレーター検証の実時間係数を測定できませんでした",
                    recoveryAction: .none, details: []
                )
            }
            verification = (output, failedInference, measuredRTF)
        } catch {
            await engine.unload()
            withExtendedLifetime(device) {}
            throw error
        }
        await engine.unload()
        withExtendedLifetime(device) {}

        let passed = verification.inferenceError == nil
            && verification.output.utf8.elementsEqual(EngineAcceleratorVerificationFixture.expectedText.utf8)
        let receipt = EngineVerificationReceipt(key: key,
            observedOutput: verification.output, passed: passed, rtf: verification.rtf, timestamp: Date())
        try checkAcceleratorVerificationCanContinue()
        let verificationID = try verificationStore.publish(receipt)
        if passed { return .pass(verificationID: verificationID, rtf: verification.rtf) }
        if let error = verification.inferenceError {
            return .fail(
                verificationID: verificationID, reason: "アクセラレーターの検証推論に失敗しました: \(error.localizedDescription)",
                observedOutput: ""
            )
        }
        return .fail(
            verificationID: verificationID, reason: "アクセラレーターの検証出力が固定テキストと一致しません",
            observedOutput: verification.output
        )
    }

    private func isAcceleratorCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? EngineCommandError)?.code == .cancelled || (error as? EngineAdapterError)?.code == .cancelled
    }

    private func checkAcceleratorVerificationCanContinue() throws {
        try Task.checkCancellation()
        guard !isShuttingDown else { throw CancellationError() }
    }

    private func acceleratorCancellationError() -> EngineCommandError {
        EngineFailures.commandError(.cancelled, "アクセラレーターの設定が中止されました", stage: .loadingModels)
    }
}
