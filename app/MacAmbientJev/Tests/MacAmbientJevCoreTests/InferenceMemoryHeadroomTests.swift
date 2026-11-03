import Testing
import MacAmbientJevCore

@Test
func memoryHeadroomReservesTheLargerOfOneGiBAndATenthOfPhysicalMemory() throws {
    let g: UInt64 = 1 << 30
    let rows: [(physical: UInt64, free: UInt64, commit: UInt64, adequate: Bool)] = [
        (8 * g, g, g, true),
        (8 * g, g - 1, 2 * g, false),
        (8 * g, 2 * g, g - 1, false),
        (20 * g, 2 * g, 2 * g, true),
        (20 * g, 2 * g - 1, 2 * g, false),
        (10 * g + 1, g + 1, g + 1, true),
        (10 * g + 1, g, g + 1, false)
    ]
    for row in rows {
        #expect(try inferenceMemoryHeadroomIsAdequate(
            physicalMemoryBytes: row.physical, freePhysicalMemoryBytes: row.free, commitHeadroomBytes: row.commit
        ) == row.adequate)
    }
}

@Test
func memoryHeadroomRejectsImpossibleMemoryFacts() {
    #expect(throws: InferenceMemoryHeadroomError.invalidPhysicalMemory) {
        try inferenceMemoryHeadroomIsAdequate(physicalMemoryBytes: 0, freePhysicalMemoryBytes: 0, commitHeadroomBytes: 0)
    }
    #expect(throws: InferenceMemoryHeadroomError.invalidPhysicalMemory) {
        try inferenceMemoryHeadroomIsAdequate(physicalMemoryBytes: 1, freePhysicalMemoryBytes: 2, commitHeadroomBytes: 2)
    }
}
