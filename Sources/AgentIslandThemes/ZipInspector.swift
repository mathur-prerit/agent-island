import Foundation
import PersonaKit

// Defensive, AppKit-free, network-free, disk-free zip central-directory parser. Lives in this target
// (NOT the App) so `AgentIslandSelfTest` can drive it with crafted hostile bytes — no `ditto`, no
// real archive. The whole point: read what a zip CLAIMS to contain (per-entry uncompressed/compressed
// size, name, unix mode) from its central directory BEFORE a single byte is extracted, so a
// decompression bomb / zip-slip / symlink can be REJECTED pre-extraction rather than after `ditto`
// has already written gigabytes (or a symlink) to disk.
//
// Every read treats the input as fully untrusted: bounds-checked little-endian reads (never trapping),
// a hard ceiling on entries iterated, and overlapping/forward/garbage offsets rejected with a typed
// error — it never crashes, never loops unboundedly, never trusts a length field to point in-bounds.
// It deliberately parses ONLY the central directory (not local headers / file data), which is the
// cheapest authoritative listing of an archive's contents.

/// One file as described by a zip central-directory header — only the fields the limit checks need.
public struct ZipEntry: Equatable, Sendable {
    public let name: String            // the entry's path as stored in the archive (untrusted)
    public let uncompressedSize: Int   // claimed inflated size (zip64-aware)
    public let compressedSize: Int     // claimed on-disk size (zip64-aware)
    public let unixMode: UInt16        // external-attributes high 16 bits → st_mode (0 if absent)

    public init(name: String, uncompressedSize: Int, compressedSize: Int, unixMode: UInt16) {
        self.name = name
        self.uncompressedSize = uncompressedSize
        self.compressedSize = compressedSize
        self.unixMode = unixMode
    }

    /// True iff the unix mode marks this entry a symbolic link (`S_IFLNK`). A symlink in a theme
    /// archive is never legitimate and a classic escape vector, so the inspector flags it for rejection.
    public var isSymlink: Bool { (unixMode & UInt16(truncatingIfNeeded: S_IFMT)) == UInt16(truncatingIfNeeded: S_IFLNK) }
}

/// Why inspecting / limit-checking an archive failed. Pure (network-free, disk-free) so the self-test
/// can assert each path; the App-side downloader wraps these into its own error type.
public enum ZipInspectionError: Error, Equatable, Sendable {
    case notAZip                      // no End-Of-Central-Directory record found (truncated/garbage/not a zip)
    case malformed                    // a header/offset/length was out of bounds, overlapping, or self-inconsistent
    case tooManyEntries(Int)          // the central directory claims more entries than we'll iterate (DoS guard)
    case unsafeName(String)           // an entry name is absolute or contains a `..` path component (zip-slip)
    case symlink(String)              // an entry's unix mode marks it a symbolic link
    case limit(PackRejection)         // the declared sizes/ratio/count tripped a PackValidator limit
}

public enum ZipInspector {
    // Zip signatures (little-endian on the wire).
    private static let eocdSignature: UInt32      = 0x06054b50   // End Of Central Directory
    private static let centralSignature: UInt32   = 0x02014b50   // Central directory file header
    private static let zip64FieldID: UInt16       = 0x0001       // Zip64 extended-information extra field

    /// The fixed (pre-variable-length) size of a central-directory file header, in bytes.
    private static let centralHeaderFixedSize = 46
    /// The fixed size of the EOCD record, in bytes (before its trailing comment).
    private static let eocdFixedSize = 22
    /// The 32-bit sentinel a size/offset uses to say "the real value is in the zip64 extra field".
    private static let zip64Sentinel: UInt32 = 0xFFFFFFFF

    /// Hard ceiling on how many central-directory entries we'll iterate, regardless of what the EOCD
    /// claims — a hostile EOCD can advertise billions of entries to make us spin. Well above the
    /// `PackLimits` file cap so a legitimate over-the-limit archive still parses and is rejected by the
    /// limit check (a clearer error) rather than this guard.
    static let maxEntriesScanned = 100_000

    // MARK: - Public API

    /// Parse the central directory of `data` into the entry list, treating every byte as hostile.
    /// Returns the entries in central-directory order, or a typed error (never throws, never crashes).
    public static func inspect(_ data: Data) -> Result<[ZipEntry], ZipInspectionError> {
        let bytes = [UInt8](data)
        guard let eocd = findEOCD(bytes) else { return .failure(.notAZip) }

        // Reject an entry count beyond our scan ceiling before we touch the directory (DoS guard).
        guard eocd.entryCount <= maxEntriesScanned else { return .failure(.tooManyEntries(eocd.entryCount)) }

        // The central directory must lie wholly within the bytes, and before the EOCD record we found.
        guard eocd.cdOffset <= eocd.eocdStart,
              eocd.cdOffset + eocd.cdSize <= bytes.count,
              eocd.cdOffset + eocd.cdSize <= eocd.eocdStart else {
            return .failure(.malformed)
        }

        var entries: [ZipEntry] = []
        entries.reserveCapacity(min(eocd.entryCount, 1024))
        var cursor = eocd.cdOffset
        let cdEnd = eocd.cdOffset + eocd.cdSize
        for _ in 0..<eocd.entryCount {
            switch parseCentralHeader(bytes, at: cursor, limit: cdEnd) {
            case .failure(let e): return .failure(e)
            case .success(let parsed):
                entries.append(parsed.entry)
                // Advance strictly forward; a non-advancing/overlapping header is malformed and would
                // otherwise let a crafted directory loop forever.
                guard parsed.next > cursor, parsed.next <= cdEnd else { return .failure(.malformed) }
                cursor = parsed.next
            }
        }
        return .success(entries)
    }

    /// Inspect + enforce the pack limits in one call — the gate the downloader runs BEFORE extraction.
    /// Rejects (in this order, returning the first failure): a non-zip/garbage archive, more entries
    /// than the file cap, any entry whose name is absolute or contains a `..` component, any symlink
    /// entry, then the aggregate size/ratio checks via `PackValidator.checkLimits`. `archiveBytes` is
    /// the on-disk size of the zip itself (for the compression-ratio check).
    public static func checkArchive(_ data: Data,
                                    archiveBytes: Int,
                                    limits: PackLimits = .init()) -> ZipInspectionError? {
        let entries: [ZipEntry]
        switch inspect(data) {
        case .failure(let e): return e
        case .success(let list): entries = list
        }

        var totalUncompressed = 0
        var largestFile = 0
        for entry in entries {
            // Path safety first (cheapest, and the highest-severity escape) — reuse PackValidator's
            // zip-slip rules (absolute / `..` / backslash / NUL), then the directory-vs-file split.
            if let rejection = PackValidator.validateAssetPath(entry.name) {
                if case .pathTraversal = rejection { return .unsafeName(entry.name) }
                return .limit(rejection)
            }
            if entry.isSymlink { return .symlink(entry.name) }
            // A directory entry (trailing slash) contributes nothing to the byte/file totals.
            if entry.name.hasSuffix("/") { continue }
            // Sum the CLAIMED uncompressed sizes — these saturate (never trap) on a hostile near-max
            // value; the limit check rejects them either way.
            totalUncompressed = totalUncompressed.addingReportingOverflow(entry.uncompressedSize).partialValue
            largestFile = max(largestFile, entry.uncompressedSize)
        }
        let fileCount = entries.filter { !$0.name.hasSuffix("/") }.count
        if let rejection = PackValidator.checkLimits(archiveBytes: archiveBytes,
                                                     uncompressedBytes: totalUncompressed,
                                                     fileCount: fileCount,
                                                     largestFileBytes: largestFile,
                                                     limits: limits) {
            return .limit(rejection)
        }
        return nil
    }

    // MARK: - End Of Central Directory

    private struct EOCD {
        let entryCount: Int   // total central-directory records
        let cdSize: Int       // size of the central directory in bytes
        let cdOffset: Int     // offset of the central directory from the start of the archive
        let eocdStart: Int    // where the EOCD record itself begins (the CD must end at/before here)
    }

    /// Locate the EOCD record by scanning backwards for its signature. The record is at the very end
    /// of a zip EXCEPT for an optional trailing comment (≤ 65535 bytes), so we scan back at most
    /// `eocdFixedSize + 0xFFFF` bytes and take the LAST signature match whose declared comment length
    /// reaches exactly the end of file (defends against a signature appearing inside file data).
    private static func findEOCD(_ bytes: [UInt8]) -> EOCD? {
        guard bytes.count >= eocdFixedSize else { return nil }
        let maxBack = min(bytes.count, eocdFixedSize + 0xFFFF)
        let lowest = bytes.count - maxBack
        var i = bytes.count - eocdFixedSize
        while i >= lowest {
            if readU32(bytes, i) == eocdSignature {
                // Comment length is the last 2 bytes of the fixed record; it must reach exactly EOF.
                guard let commentLen = readU16Opt(bytes, i + 20) else { i -= 1; continue }
                if i + eocdFixedSize + Int(commentLen) == bytes.count {
                    guard let entryCount = readU16Opt(bytes, i + 10),
                          let cdSize = readU32Opt(bytes, i + 12),
                          let cdOffset = readU32Opt(bytes, i + 16) else { return nil }
                    return EOCD(entryCount: Int(entryCount),
                                cdSize: Int(cdSize),
                                cdOffset: Int(cdOffset),
                                eocdStart: i)
                }
            }
            i -= 1
        }
        return nil
    }

    // MARK: - Central directory file header

    private struct ParsedHeader { let entry: ZipEntry; let next: Int }

    /// Parse one central-directory file header starting at `offset`, with `limit` the exclusive end of
    /// the central directory. Bounds-checks every field; resolves zip64 sizes from the extra field when
    /// the 32-bit slots are sentinels. Returns the entry plus the offset of the next header.
    private static func parseCentralHeader(_ bytes: [UInt8], at offset: Int,
                                           limit: Int) -> Result<ParsedHeader, ZipInspectionError> {
        guard offset >= 0, offset + centralHeaderFixedSize <= limit,
              readU32(bytes, offset) == centralSignature else {
            return .failure(.malformed)
        }
        // Field offsets within the central-directory header (PKZip APPNOTE §4.3.12).
        guard let compRaw   = readU32Opt(bytes, offset + 20),     // compressed size
              let uncompRaw = readU32Opt(bytes, offset + 24),     // uncompressed size
              let nameLen   = readU16Opt(bytes, offset + 28),     // file name length
              let extraLen  = readU16Opt(bytes, offset + 30),     // extra field length
              let commentLen = readU16Opt(bytes, offset + 32),    // file comment length
              let externalAttrs = readU32Opt(bytes, offset + 38)  // external file attributes
        else { return .failure(.malformed) }

        let nameStart = offset + centralHeaderFixedSize
        let extraStart = nameStart + Int(nameLen)
        let commentStart = extraStart + Int(extraLen)
        let next = commentStart + Int(commentLen)
        // The whole variable-length tail (name + extra + comment) must stay within the central dir.
        guard nameStart <= limit, extraStart <= limit, commentStart <= limit, next <= limit else {
            return .failure(.malformed)
        }

        // File name: decode the raw bytes as UTF-8 (lenient — a name that isn't valid UTF-8 is treated
        // as opaque/decoded-with-replacement rather than crashing; the path checks still apply).
        let nameBytes = Array(bytes[nameStart..<(nameStart + Int(nameLen))])
        let name = String(decoding: nameBytes, as: UTF8.self)

        // The external-attributes high 16 bits carry the unix st_mode for archives created on unix.
        let unixMode = UInt16(truncatingIfNeeded: externalAttrs >> 16)

        // Resolve sizes, reading the zip64 extra field when either 32-bit slot is the sentinel.
        var compressed = Int(compRaw)
        var uncompressed = Int(uncompRaw)
        if compRaw == zip64Sentinel || uncompRaw == zip64Sentinel {
            switch resolveZip64Sizes(bytes, extraStart: extraStart, extraLen: Int(extraLen),
                                     compIsSentinel: compRaw == zip64Sentinel,
                                     uncompIsSentinel: uncompRaw == zip64Sentinel) {
            case .failure(let e): return .failure(e)
            case .success(let resolved):
                if let u = resolved.uncompressed { uncompressed = u }
                if let c = resolved.compressed { compressed = c }
            }
        }
        guard uncompressed >= 0, compressed >= 0 else { return .failure(.malformed) }

        return .success(ParsedHeader(
            entry: ZipEntry(name: name, uncompressedSize: uncompressed,
                            compressedSize: compressed, unixMode: unixMode),
            next: next))
    }

    /// Walk the extra-field block for the zip64 extended-information record (id 0x0001) and pull the
    /// 64-bit uncompressed/compressed sizes that replace the sentinel 32-bit slots. The zip64 field
    /// packs only the values whose 32-bit slot was a sentinel, IN ORDER (uncompressed, then compressed).
    private static func resolveZip64Sizes(_ bytes: [UInt8], extraStart: Int, extraLen: Int,
                                          compIsSentinel: Bool,
                                          uncompIsSentinel: Bool) -> Result<(uncompressed: Int?, compressed: Int?), ZipInspectionError> {
        var p = extraStart
        let end = extraStart + extraLen
        // Each extra field is a 2-byte id + 2-byte data length + data.
        while p + 4 <= end {
            guard let fieldID = readU16Opt(bytes, p), let dataLen = readU16Opt(bytes, p + 2) else {
                return .failure(.malformed)
            }
            let dataStart = p + 4
            let dataEnd = dataStart + Int(dataLen)
            guard dataEnd <= end else { return .failure(.malformed) }
            if fieldID == zip64FieldID {
                var q = dataStart
                var uncompressed: Int?
                var compressed: Int?
                if uncompIsSentinel {
                    guard let v = readU64Opt(bytes, q, within: dataEnd) else { return .failure(.malformed) }
                    uncompressed = clampToInt(v); q += 8
                }
                if compIsSentinel {
                    guard let v = readU64Opt(bytes, q, within: dataEnd) else { return .failure(.malformed) }
                    compressed = clampToInt(v); q += 8
                }
                return .success((uncompressed, compressed))
            }
            p = dataEnd
        }
        // A sentinel size with no zip64 field to back it is a malformed/hostile header.
        return .failure(.malformed)
    }

    // MARK: - Bounds-checked little-endian readers (never trap)

    /// A non-optional 32-bit read for signature comparisons where the caller has already bounds-checked
    /// the surrounding fixed-size region; returns 0 (never a valid signature) if somehow out of range.
    private static func readU32(_ bytes: [UInt8], _ i: Int) -> UInt32 {
        readU32Opt(bytes, i) ?? 0
    }

    private static func readU16Opt(_ bytes: [UInt8], _ i: Int) -> UInt16? {
        guard i >= 0, i + 2 <= bytes.count else { return nil }
        return UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
    }

    private static func readU32Opt(_ bytes: [UInt8], _ i: Int) -> UInt32? {
        guard i >= 0, i + 4 <= bytes.count else { return nil }
        return UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8)
             | (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24)
    }

    /// A 64-bit read bounded by BOTH the byte buffer and a caller-supplied `within` end (the extra
    /// field's data region), so a short zip64 field can't read into adjacent bytes.
    private static func readU64Opt(_ bytes: [UInt8], _ i: Int, within end: Int) -> UInt64? {
        guard i >= 0, i + 8 <= bytes.count, i + 8 <= end else { return nil }
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(bytes[i + k]) << (8 * k) }
        return v
    }

    /// Clamp a 64-bit size to `Int`, saturating at `Int.max` rather than trapping — a hostile zip64
    /// size near `UInt64.max` becomes a huge-but-finite `Int` that the limit check then rejects.
    private static func clampToInt(_ v: UInt64) -> Int {
        v > UInt64(Int.max) ? Int.max : Int(v)
    }
}
