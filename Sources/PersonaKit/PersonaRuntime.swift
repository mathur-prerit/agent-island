/// Assigns each session a persona, locked for that session's lifetime.
public enum PersonaRuntime {
    /// Deterministically pick a persona from `pool` for a session id. Stable for that id
    /// via an FNV-1a hash — no storage, and (unlike Swift's per-run-randomized
    /// `hashValue`) the same id always maps to the same persona across launches, while
    /// different ids spread across the pool. Returns nil for an empty pool.
    public static func persona(forSessionID id: String, pool: [Persona]) -> Persona? {
        guard !pool.isEmpty else { return nil }
        var hash: UInt64 = 14695981039346656037  // FNV-1a 64-bit offset basis
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211         // FNV-1a 64-bit prime
        }
        return pool[Int(hash % UInt64(pool.count))]
    }
}
