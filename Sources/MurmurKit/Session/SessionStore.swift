import Foundation

/// Owns `$MURMUR_HOME/recordings/<id>/` (SPEC §7.1): audio.caf (authoritative), audio.wav
/// (derived cache), meta.json (atomic), transcript.txt. Audio is sacred — a transcript can
/// always be regenerated.
public actor SessionStore {
    public let root: URL

    public init(root: URL = Paths.recordings) {
        self.root = root
    }

    // MARK: paths

    public nonisolated func dir(_ id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }
    public nonisolated func cafURL(_ id: String) -> URL { dir(id).appendingPathComponent("audio.caf") }
    public nonisolated func wavURL(_ id: String) -> URL { dir(id).appendingPathComponent("audio.wav") }
    public nonisolated func metaURL(_ id: String) -> URL { dir(id).appendingPathComponent("meta.json") }
    public nonisolated func transcriptURL(_ id: String) -> URL {
        dir(id).appendingPathComponent("transcript.txt")
    }

    // MARK: lifecycle

    public func create(model: String) throws -> SessionMeta {
        let id = Self.newID()
        try FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
        let meta = SessionMeta(id: id, model: model)
        try save(meta)
        return meta
    }

    /// Atomic meta write: temp file + rename, so a crash never leaves a half-written meta.json.
    public func save(_ meta: SessionMeta) throws {
        var m = meta
        m.updatedAt = Date()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(m)
        let tmp = dir(meta.id).appendingPathComponent(".meta.json.tmp")
        try data.write(to: tmp, options: [.atomic])
        _ = try FileManager.default.replaceItemAt(metaURL(meta.id), withItemAt: tmp)
        if let transcript = m.transcript, !transcript.isEmpty {
            try? transcript.write(to: transcriptURL(meta.id), atomically: true, encoding: .utf8)
        }
    }

    public func load(_ id: String) -> SessionMeta? {
        guard let data = try? Data(contentsOf: metaURL(id)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(SessionMeta.self, from: data)
    }

    /// All sessions with readable meta, sorted by id (ids sort chronologically).
    public func all() -> [SessionMeta] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return entries.sorted().compactMap { load($0) }
    }

    /// Dirs that have authoritative audio but no readable meta — crash leftovers (SPEC §7.3).
    /// Adopt them as `recorded` so launch recovery transcribes from the saved audio.
    public func adoptOrphans(model: String) -> [SessionMeta] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var adopted: [SessionMeta] = []
        for id in entries.sorted() {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir(id).path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard load(id) == nil, fm.fileExists(atPath: cafURL(id).path) else { continue }
            var meta = SessionMeta(id: id, model: model, state: .recorded)
            meta.lastError = "adopted orphan dir (crash left no meta.json)"
            if let m = try? { try save(meta); return meta }() {
                adopted.append(m)
                Log.warn("session.orphan_adopted", msg: "id=\(id)")
            }
        }
        return adopted
    }

    public func delete(_ id: String) {
        try? FileManager.default.removeItem(at: dir(id))
    }

    /// `yyyyMMdd-HHmmssSSS-xxxx` — sortable, unique enough for one machine.
    private static func newID() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmssSSS"
        let rand = String((0..<4).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        return f.string(from: Date()) + "-" + rand
    }
}
