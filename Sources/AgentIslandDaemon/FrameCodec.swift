import Foundation

/// Length-prefixed framing for the daemon's Unix-domain socket: a 4-byte big-endian
/// length followed by the payload, with a hard 64 KB cap to bound per-message memory.
public enum FrameCodec {
    public static let maxMessageBytes = 64 * 1024

    /// Encode payload as a 4-byte big-endian length prefix + payload bytes.
    public static func encode(_ payload: Data) -> Data {
        var out = Data(capacity: 4 + payload.count)
        var beLength = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &beLength) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// Decode a 4-byte big-endian length prefix to an Int (or -1 if fewer than 4 bytes).
    public static func decodeLength(_ bytes: [UInt8]) -> Int {
        guard bytes.count >= 4 else { return -1 }
        let v = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
              | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        return Int(v)
    }

    /// Whether a declared frame length is acceptable: non-negative and within the cap.
    public static func isAcceptableLength(_ length: Int) -> Bool {
        length >= 0 && length <= maxMessageBytes
    }
}
