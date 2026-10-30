import Testing
@testable import MacAmbientJevCore

@Test
func inferenceAdmissionPrioritizesBudgetAndWorkloadRules() throws {
    let g: UInt64 = 1 << 30
    let zero = InferenceEnvelope.measured(loadPeakBytes: 0, residentBytes: 0, scratchBytes: 0, concurrentBytes: 0)
    let large = InferenceEnvelope.measured(loadPeakBytes: 4*g, residentBytes: 4*g, scratchBytes: 4*g, concurrentBytes: 1)
    let rows: [(UInt64, UInt64, InferenceEnvelope, InferenceRTF, Int, Int, InferenceWorkload, Bool, InferenceAdmission)] = [
        (g, g, zero, .measured(0.5), 2, 8, .live, false, .admit),
        (g-1, g, .unmeasured, .measured(0.5), 2, 8, .live, false, .block(.insufficientPhysicalMemory)),
        (2*g, 2*g, .unmeasured, .stale, 2, 8, .live, false, .warn(.envelopeUnmeasured)),
        (2*g, g-1, .unmeasured, .measured(0.5), 2, 8, .live, false, .block(.insufficientCommitHeadroom)),
        (2*g, 2*g, .stale, .unmeasured, 2, 8, .live, false, .warn(.envelopeStale)),
        (2*g, g-1, .stale, .measured(0.5), 2, 8, .live, false, .block(.insufficientCommitHeadroom)),
        (2*g, 2*g, zero, .unmeasured, 2, 8, .live, false, .warn(.rtfUnmeasured)),
        (2*g, 2*g, zero, .stale, 2, 8, .live, false, .warn(.rtfStale)),
        (2*g, 2*g, .measured(loadPeakBytes: 0, residentBytes: 2*g, scratchBytes: 0, concurrentBytes: 0), .measured(0.5), 2, 8, .live, false, .block(.insufficientPhysicalMemory)),
        (2*g, g+1, .measured(loadPeakBytes: 2, residentBytes: 0, scratchBytes: 0, concurrentBytes: 0), .measured(0.5), 2, 8, .load, false, .block(.insufficientCommitHeadroom)),
        (2*g, g-1, zero, .measured(0.5), 2, 8, .live, false, .block(.insufficientCommitHeadroom)),
        (2*g, 2*g, zero, .measured(0.5), 2, 8, .live, true, .block(.lowMemory)),
        (2*g, 2*g, zero, .measured(0.71), 2, 8, .live, false, .block(.liveTooSlow)),
        (2*g, 2*g, zero, .measured(0.71), 2, 8, .load, false, .admit),
        (2*g, 2*g, zero, .measured(0.71), 2, 8, .finalization, false, .admit),
        (6*g, 6*g, large, .measured(0.5), 2, 8, .load, false, .admit),
        (6*g, 6*g, large, .measured(0.5), 2, 8, .live, false, .block(.insufficientPhysicalMemory)),
        (6*g, 6*g, large, .measured(0.5), 2, 8, .finalization, false, .block(.insufficientPhysicalMemory)),
        (2*g, 2*g, zero, .measured(0.5), 0, 1, .live, false, .block(.unsupportedCPUCount)),
        (2*g, 2*g, zero, .measured(0.5), 1, 2, .live, false, .admit),
        (2*g, 2*g, zero, .measured(0.5), 2, 2, .live, false, .block(.invalidThreads)),
        (2*g, 2*g, zero, .measured(0.5), 1, 8, .live, false, .admit),
        (2*g, 2*g, zero, .measured(0.5), 4, 8, .live, false, .admit),
        (2*g, 2*g, zero, .measured(0.5), 5, 8, .live, false, .block(.invalidThreads)),
        (2*g, 2*g, zero, .measured(0.5), 0, 8, .live, false, .block(.invalidThreads))
    ]
    for (free, commit, envelope, rtf, threads, cpus, workload, low, expected) in rows {
        #expect(try admitInference(physicalMemoryBytes: 8*g, freePhysicalMemoryBytes: free, commitHeadroomBytes: commit, envelope: envelope, measuredRTF: rtf, threads: threads, logicalCPUCount: cpus, workload: workload, lowMemorySignal: low) == expected)
    }
    #expect(try admitInference(physicalMemoryBytes: 10*g+1, freePhysicalMemoryBytes: g, commitHeadroomBytes: g, envelope: zero, measuredRTF: .measured(0.5), threads: 1, logicalCPUCount: 2, workload: .live, lowMemorySignal: false) == .block(.insufficientPhysicalMemory))
}

