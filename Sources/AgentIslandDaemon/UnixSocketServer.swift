import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A Unix-domain socket server for the daemon: parent dir `0700`, socket `0600`, peers
/// restricted to the daemon's euid (`PeerCred`), messages length-framed and capped at
/// 64 KB (`FrameCodec`). Binding/listening is real; the accept loop is driven by live
/// hook clients (integration), not the headless self-test — which covers the framing
/// and peer-cred logic directly via `SocketRoundTrip` and `PeerCred`.
public final class UnixSocketServer {
    public let socketPath: String
    private var listenFD: Int32 = -1

    public init(socketPath: String) { self.socketPath = socketPath }

    public enum ServerError: Error, Equatable {
        case pathTooLong
        case socketFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
    }

    /// Create the parent dir (0700), remove any stale socket, bind (0600), and listen.
    public func start(backlog: Int32 = 16) throws {
        let dir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        unlink(socketPath) // drop a stale socket from a prior run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { close(fd); throw ServerError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBytes { src in
                dst.copyMemory(from: src) // src.count < capacity == dst.count; leaves trailing NUL
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else { close(fd); throw ServerError.bindFailed(errno) }

        chmod(socketPath, 0o600)
        guard listen(fd, backlog) == 0 else { close(fd); throw ServerError.listenFailed(errno) }
        listenFD = fd
    }

    public func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(socketPath)
    }
}
