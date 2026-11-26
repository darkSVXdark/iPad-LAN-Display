import Foundation
import CryptoKit

struct Adaptive {
    var quality = 0.82
    var fps = 60.0
    var cycle = 1.0 / 60.0
    mutating func observe(_ seconds: Double) {
        guard seconds.isFinite, seconds > 0, seconds <= 4 else {return}
        cycle = cycle * 0.8 + seconds * 0.2
        // Recompute on every ACK; no dead band that traps the stream at 5 FPS.
        fps = min(60, max(5, 0.95 / cycle))
        if cycle > 0.12 {quality = max(0.70, quality - 0.01)}
        else if cycle < 0.075 {quality = min(0.90, quality + 0.002)}
    }
}
func websocketAccept(_ key: String) -> String {
    Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
}
func wsFrame(_ data: Data, opcode: UInt8 = 2) -> Data {
    var out = Data([0x80 | opcode])
    if data.count < 126 { out.append(UInt8(data.count)) }
    else if data.count <= 65535 { out.append(126); out.append(UInt8(data.count >> 8)); out.append(UInt8(data.count & 255)) }
    else { out.append(127); var length = UInt64(data.count).bigEndian; withUnsafeBytes(of: &length) { out.append(contentsOf: $0) } }
    out.append(data); return out
}
// Only small, final, masked control/ACK messages are accepted from the browser.
func consumeWS(_ input: inout Data) throws -> (UInt8, Data)? {
    let b = [UInt8](input)
    guard b.count >= 2 else { return nil }
    guard b[0] & 0x80 != 0, b[0] & 0x70 == 0, b[1] & 0x80 != 0, b[1] & 127 < 126 else { throw NSError(domain: "WS", code: 1) }
    let n = Int(b[1] & 127)
    guard b.count >= 6+n else { return nil }
    let payload = Data((0..<n).map { b[6+$0] ^ b[2+$0%4] })
    input.removeFirst(6+n)
    return (b[0]&15, payload)
}

// A failed capture must never turn the discovery timer into a permission prompt loop.
// Only a deliberate user action can clear this latch.
struct CaptureAccessGate {
    private(set) var paused = false
    func permitsEnumeration(preflight: () -> Bool) -> Bool {
        !paused && preflight()
    }
    mutating func failed() { paused = true }
    mutating func userRetry() { paused = false }
}
