import Foundation

/// One filename component accepted by both POSIX filesystems and Win32.
enum PortableFileName {
    private static let forbidden = CharacterSet(charactersIn: "<>:\"/\\|?*")
        .union(CharacterSet(charactersIn: Unicode.Scalar(0)!...Unicode.Scalar(31)!))

    static func isReserved(_ name: String) -> Bool {
        let base = name.split(separator: ".", omittingEmptySubsequences: false)[0].uppercased()
        if ["CON", "PRN", "AUX", "NUL"].contains(base) { return true }
        return (base.hasPrefix("COM") || base.hasPrefix("LPT"))
            && base.count == 4 && "123456789¹²³".contains(base.last!)
    }

    static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && name.unicodeScalars.allSatisfy { !forbidden.contains($0) }
            && name.last != "." && name.last != " " && !isReserved(name)
    }

    static func sanitize(_ name: String) -> String {
        var result = String(String.UnicodeScalarView(name.unicodeScalars.map {
            forbidden.contains($0) ? Unicode.Scalar(45)! : $0
        }))
        if result.unicodeScalars.first?.value == 46 {
            result.replaceSubrange(result.startIndex..<result.unicodeScalars.index(after: result.unicodeScalars.startIndex), with: "-")
        }
        // Replace every trailing dot/space, including consecutive mixed suffixes.
        let suffix = result.reversed().prefix { $0 == "." || $0 == " " }.count
        if suffix > 0 {
            result.replaceSubrange(result.index(result.endIndex, offsetBy: -suffix)..<result.endIndex,
                                   with: String(repeating: "-", count: suffix))
        }
        if !result.isEmpty && isReserved(result) { result = "-" + result }
        return result
    }
}
