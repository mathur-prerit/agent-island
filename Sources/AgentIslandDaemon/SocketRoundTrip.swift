import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Exercises `FrameCodec` over a real `AF_UNIX` socket pair — a deterministic round-trip
/// smoke test of the framing without bind/listen/accept or the filesystem.
public enum SocketRoundTrip {
    /// Send `payload` as a framed message through one end of a socketpair and read it
    /// back from the other, returning the decoded payload (nil on any socket/frame error).
    public static func loopback(_ payload: Data) -> Data? {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { return nil }
        let writer = fds[0], reader = fds[1]
        defer { close(writer); close(reader) }

        let frame = FrameCodec.encode(payload)
        let sent = frame.withUnsafeBytes { raw in write(writer, raw.baseAddress, raw.count) }
        guard sent == frame.count else { return nil }

        var lengthBytes = [UInt8](repeating: 0, count: 4)
        guard readFully(reader, &lengthBytes, 4) else { return nil }
        let length = FrameCodec.decodeLength(lengthBytes)
        guard FrameCodec.isAcceptableLength(length) else { return nil }
        if length == 0 { return Data() }

        var payloadBytes = [UInt8](repeating: 0, count: length)
        guard readFully(reader, &payloadBytes, length) else { return nil }
        return Data(payloadBytes)
    }

    private static func readFully(_ fd: Int32, _ buffer: inout [UInt8], _ count: Int) -> Bool {
        var total = 0
        while total < count {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress!.advanced(by: total), count - total)
            }
            if n <= 0 { return false }
            total += n
        }
        return true
    }
}
