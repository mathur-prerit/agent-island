import Foundation

/// Hard limits enforced before/while loading a Persona Pack archive, to defend against
/// oversized packs and zip bombs. Checked before extraction where possible.
public struct PackLimits: Sendable, Equatable {
    public var maxArchiveBytes: Int
    public var maxUncompressedBytes: Int
    public var maxFileCount: Int
    public var maxFileBytes: Int
    public var maxCompressionRatio: Double

    public init(maxArchiveBytes: Int = 10 * 1024 * 1024,
                maxUncompressedBytes: Int = 50 * 1024 * 1024,
                maxFileCount: Int = 100,
                maxFileBytes: Int = 5 * 1024 * 1024,
                maxCompressionRatio: Double = 100) {
        self.maxArchiveBytes = maxArchiveBytes
        self.maxUncompressedBytes = maxUncompressedBytes
        self.maxFileCount = maxFileCount
        self.maxFileBytes = maxFileBytes
        self.maxCompressionRatio = maxCompressionRatio
    }
}
