import Foundation

/// The app was called Transcriptaze. On first launch as Scriptorium, its notes,
/// highlights, voice model and settings move to the new name, once.
public enum Rename {
    static let oldName = "Transcriptaze"
    static let oldDefaultsDomain = "com.transcriptaze.app"

    public static func migrate() {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if ProcessInfo.processInfo.environment["SCRIPTORIUM_NOTES_DIR"] == nil {
            move(documents.appendingPathComponent(oldName), to: NoteStore.defaultFolder)
        }
        move(NoteStore.defaultFolder.appendingPathComponent(".transcriptaze"), to: NoteStore.defaultFolder.appendingPathComponent(".scriptorium"))
        move(support.appendingPathComponent(oldName), to: support.appendingPathComponent("Scriptorium"))

        let defaults = UserDefaults.standard
        if defaults.object(forKey: "migratedFromTranscriptaze") == nil {
            for (key, value) in defaults.persistentDomain(forName: oldDefaultsDomain) ?? [:] where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
            defaults.set(true, forKey: "migratedFromTranscriptaze")
        }
    }

    /// Moves `old` to `new` when only the old one exists.
    static func move(_ old: URL, to new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: old, to: new)
    }
}
