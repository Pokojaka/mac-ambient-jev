import Foundation
import WinSDK
import MacAmbientJevEngineHost
import MacAmbientJevPortableRuntime
import MacAmbientJevWindowsSupport

let message = "Usage: MacAmbientJevEngine\n\(EngineHostError.unavailable.localizedDescription)\n"
try FileHandle.standardError.write(contentsOf: Data(message.utf8))
ExitProcess(2)
