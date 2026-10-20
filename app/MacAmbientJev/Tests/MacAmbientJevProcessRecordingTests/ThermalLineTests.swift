import Foundation
import Testing
@testable import MacAmbientJevProcessRecording

@Test(arguments: [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical])
func thermalJSONLUsesFoundationStateDescription(_ state: ProcessInfo.ThermalState) throws {
    let expectedState: String
    switch state {
    case .nominal:
        expectedState = "nominal"
    case .fair:
        expectedState = "fair"
    case .serious:
        expectedState = "serious"
    case .critical:
        expectedState = "critical"
    @unknown default:
        preconditionFailure("未知の熱状態です")
    }

    let line = try RunMonitor.thermalLine(
        runID: "run", timestamp: "2026-01-02T03:04:05Z", state: state
    )
    let expectedLine = "{\"run_id\":\"run\",\"state\":\"\(expectedState)\",\"timestamp\":\"2026-01-02T03:04:05Z\"}\n"
    let actualLine = try #require(String(data: line, encoding: .utf8))
    #expect(actualLine == expectedLine)

    let object = try #require(JSONSerialization.jsonObject(with: line) as? [String: String])
    #expect(object["state"] == String(describing: state))
}
