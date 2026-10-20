import Foundation
import Testing
@testable import MacAmbientJevCore

@Test(arguments: [
    ("", "d41d8cd98f00b204e9800998ecf8427e"),
    ("a", "0cc175b9c0f1b6a831c399e269772661"),
    ("abc", "900150983cd24fb0d6963f7d28e17f72"),
    ("message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
    ("abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b"),
    (
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
        "d174ab98d277d9f5a5611c2c9f419d9f"
    ),
    (
        "12345678901234567890123456789012345678901234567890123456789012345678901234567890",
        "57edf4a22be3c955ac49da2e2107b67a"
    ),
])
func rfc1321VectorsMatch(input: String, expectedHex: String) {
    var digest = FLACMD5()
    digest.update(Array(input.utf8))
    #expect(hexadecimal(digest.finalize()) == expectedHex)
}

@Test(arguments: [55, 56, 63, 64, 65])
func chunkSplitsAroundBlockBoundariesMatchSingleUpdate(length: Int) {
    let bytes = (0..<length).map { UInt8(($0 * 31 + 17) & 0xff) }
    var singleUpdate = FLACMD5()
    singleUpdate.update(bytes)
    let expected = singleUpdate.finalize()

    for split in 0...length {
        var chunked = FLACMD5()
        chunked.update(Array(bytes[..<split]))
        chunked.update(Array(bytes[split...]))
        #expect(chunked.finalize() == expected)
    }
}

@Test func millionRepeatedBytesMatchRFC1321Vector() {
    var digest = FLACMD5()
    let chunk = [UInt8](repeating: 0x61, count: 1_000)
    for _ in 0..<1_000 {
        digest.update(chunk)
    }
    #expect(hexadecimal(digest.finalize()) == "7707d6ae4e027c70eea2a935c2296f21")
}

@Test func signedSamplesAreHashedAsLittleEndianPCM() {
    var digest = FLACMD5()
    digest.update(samples: [0x1234, -2, Int16.min, Int16.max])
    #expect(hexadecimal(digest.finalize()) == "bc8e03914a72da6bb8af469436e6f6bc")
}

private func hexadecimal(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}
