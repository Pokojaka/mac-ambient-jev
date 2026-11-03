import Foundation
import WinSDK

/// Where the running engine executable lives. The app ships its read-only models in `models` beside it.
enum EngineExecutableLocation {
    private static let initialCapacity = 512
    private static let maximumCapacity = 32_768

    static func bundledModelsRoot() throws -> URL {
        try directory().appending(path: "models", directoryHint: .isDirectory)
    }

    static func directory() throws -> URL {
        var capacity = initialCapacity
        while capacity <= maximumCapacity {
            var buffer = [WCHAR](repeating: 0, count: capacity)
            let length = Int(GetModuleFileNameW(nil, &buffer, DWORD(capacity)))
            guard length > 0 else {
                throw EngineLaunchError.startup("エンジンの実行ファイルの場所を取得できません (GetModuleFileNameW: \(GetLastError()))")
            }
            if length < capacity {
                let path = String(decoding: buffer[0..<length], as: UTF16.self)
                return URL(fileURLWithPath: path, isDirectory: false).deletingLastPathComponent()
            }
            capacity *= 2
        }
        throw EngineLaunchError.startup("エンジンの実行ファイルのパスが \(maximumCapacity) 文字を超えています")
    }
}
