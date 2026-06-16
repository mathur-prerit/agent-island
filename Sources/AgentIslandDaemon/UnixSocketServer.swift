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

    /// Block accepting connections; for each, verify the peer's uid (R33), read one
    /// framed message, hand the payload to `handler`, then close. Runs until `stop()`.
    /// Intended to run on a background thread.
    public func acceptLoop(_ handler: @escaping (Data) -> Void) {
        let myUID = UInt32(getuid())
        while listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            if client < 0 { continue }
            defer { close(client) }
            if let euid = PeerCred.peerEUID(of: client),
               PeerCred.isAuthorized(peerEUID: euid, daemonEUID: myUID),
               let payload = readFrame(client) {
                handler(payload)
            }
        }
    }

    private func readFrame(_ fd: Int32) -> Data? {
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        guard readFully(fd, &lengthBytes, 4) else { return nil }
        let length = FrameCodec.decodeLength(lengthBytes)
        guard FrameCodec.isAcceptableLength(length), length > 0 else { return nil }
        var payload = [UInt8](repeating: 0, count: length)
        guard readFully(fd, &payload, length) else { return nil }
        return Data(payload)
    }

    private func readFully(_ fd: Int32, _ buffer: inout [UInt8], _ count: Int) -> Bool {
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

    public func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(socketPath)
    }
}
