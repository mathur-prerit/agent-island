import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Connects to the daemon's Unix-domain socket and sends one framed message. Used by the
/// hook-bridge CLI: fire-and-forget, returns false fast if the daemon isn't listening so
/// a hook never blocks Claude Code.
public enum UnixSocketClient {
    public static func send(_ payload: Data, toSocketPath path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            bytes.withUnsafeBytes { dst.copyMemory(from: $0) }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else { return false }

        let frame = FrameCodec.encode(payload)
        let sent = frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return sent == frame.count
    }
}
