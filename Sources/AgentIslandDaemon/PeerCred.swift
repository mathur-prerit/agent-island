import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Restricts socket peers to the daemon's own user (R33): a connecting process is
/// accepted only if its effective uid matches the daemon's.
public enum PeerCred {
    /// Pure authorization decision.
    public static func isAuthorized(peerEUID: UInt32, daemonEUID: UInt32) -> Bool {
        peerEUID == daemonEUID
    }

    /// The effective uid of the peer connected on `fd`, via `getpeereid` (nil on error).
    /// The kernel records peer credentials at connect time — a peer cannot spoof them.
    public static func peerEUID(of fd: Int32) -> UInt32? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        return UInt32(uid)
    }
}
