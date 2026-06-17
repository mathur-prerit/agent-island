import Foundation

/// File-level wrapper around `SettingsMerge`: reads a settings.json, merges, and writes
/// it back **safely** — backing up the original and writing atomically, and aborting
/// (never clobbering) if the existing file is malformed JSON.
public enum SettingsFile {
    public enum FileError: Error, Equatable {
        case invalidExistingJSON
        case writeFailed
    }

    public static func install(settingsPath: String, command: String, events: [String]) throws {
        let url = URL(fileURLWithPath: settingsPath)
        let exists = FileManager.default.fileExists(atPath: settingsPath)
        let existing = exists ? ((try? Data(contentsOf: url)) ?? Data()) : Data()

        switch SettingsMerge.install(existing: existing, command: command, events: events) {
        case .failure(.invalidJSON):
            throw FileError.invalidExistingJSON  // do NOT overwrite a file we couldn't parse
        case .success(let merged):
            // Back up only the FIRST time (when no .bak exists yet), so a re-install doesn't
            // overwrite the user's pristine config with an already-hooked version.
            let backupPath = settingsPath + ".bak"
            if exists, !FileManager.default.fileExists(atPath: backupPath),
               let original = try? Data(contentsOf: url) {
                try? original.write(to: URL(fileURLWithPath: backupPath))
            }
            do { try merged.write(to: url, options: .atomic) }  // temp-then-rename
            catch { throw FileError.writeFailed }
        }
    }

    public static func uninstall(settingsPath: String, command: String) throws {
        let url = URL(fileURLWithPath: settingsPath)
        guard FileManager.default.fileExists(atPath: settingsPath) else { return }
        let existing = (try? Data(contentsOf: url)) ?? Data()
        switch SettingsMerge.uninstall(existing: existing, command: command) {
        case .failure(.invalidJSON):
            throw FileError.invalidExistingJSON
        case .success(let cleaned):
            do { try cleaned.write(to: url, options: .atomic) }
            catch { throw FileError.writeFailed }
        }
    }
}
