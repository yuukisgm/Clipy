//
//  SQLiteClipStore.swift
//
//  Clipy
//

import Cocoa
import PINCache
import SQLite3

final class SQLiteClipStore {
    static let shared = SQLiteClipStore()
    static let snippetsDidChangeNotification = Notification.Name("SQLiteClipStoreSnippetsDidChangeNotification")

    private let queue = DispatchQueue(label: "com.yuukisgm.Clipy.sqlite-store", qos: .userInitiated)
    private var db: OpaquePointer?
    private var clipDataCache = [String: CPYClipData]()
    private var clipDataCacheOrder = [String]()
    private let clipDataCacheLimit = 10

    private init() {
        queue.sync {
            open()
            migrate()
        }
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    func warmUp() {
        queue.sync {}
    }

    func purgeSessionCaches() {
        queue.sync {
            clipDataCache.removeAll(keepingCapacity: true)
            clipDataCacheOrder.removeAll(keepingCapacity: true)
        }
    }
}

// MARK: - Clips
extension SQLiteClipStore {
    func hasClips() -> Bool {
        return queue.sync {
            Int.scalar(db, sql: "SELECT COUNT(*) FROM clips") > 0
        }
    }

    func saveClip(_ clip: CPYClip) {
        queue.sync {
            let oldPath = String.scalar(db,
                                        sql: "SELECT data_path FROM clips WHERE data_hash = ?",
                                        bindings: [.text(clip.dataHash)])
            execute("""
                INSERT INTO clips(data_hash, data_path, title, primary_type, update_time, thumbnail_path, is_color_code)
                VALUES(?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(data_hash) DO UPDATE SET
                    data_path = excluded.data_path,
                    title = excluded.title,
                    primary_type = excluded.primary_type,
                    update_time = excluded.update_time,
                    thumbnail_path = excluded.thumbnail_path,
                    is_color_code = excluded.is_color_code
                """,
                [.text(clip.dataHash),
                 .text(clip.dataPath),
                 .text(clip.title),
                 .text(clip.primaryType),
                 .int(clip.updateTime),
                 .text(clip.thumbnailPath),
                 .int(clip.isColorCode ? 1 : 0)])
            if let oldPath = oldPath, oldPath != clip.dataPath {
                try? FileManager.default.removeItem(atPath: oldPath)
            }
            trimClipDataCache(removedHash: clip.dataHash)
        }
    }

    func clips(limit: Int, previewLength: Int, ascending: Bool) -> [CPYClip] {
        let order = ascending ? "ASC" : "DESC"
        let effectiveLimit = max(limit, 0)
        let effectivePreviewLength = max(previewLength, 1)
        return queue.sync {
            queryClips("""
                SELECT data_hash, data_path, substr(title, 1, ?), primary_type, update_time, thumbnail_path, is_color_code
                FROM clips
                ORDER BY update_time \(order)
                LIMIT ?
                """,
                [.int(effectivePreviewLength), .int(effectiveLimit)])
        }
    }

    func clip(dataHash: String, previewLength: Int) -> CPYClip? {
        return queue.sync {
            queryClips("""
                SELECT data_hash, data_path, substr(title, 1, ?), primary_type, update_time, thumbnail_path, is_color_code
                FROM clips
                WHERE data_hash = ?
                LIMIT 1
                """,
                [.int(max(previewLength, 1)), .text(dataHash)]).first
        }
    }

    func searchClips(query: String, limit: Int, previewLength: Int, ascending: Bool) -> [CPYClip] {
        let order = ascending ? "ASC" : "DESC"
        let terms = Self.searchTerms(for: query)
        guard !terms.isEmpty else {
            return clips(limit: limit, previewLength: previewLength, ascending: ascending)
        }
        let ftsQuery = Self.ftsQuery(for: terms)
        let likeClauses = terms.map { _ in "c.title LIKE ? ESCAPE char(92)" }.joined(separator: " AND ")
        let effectiveLimit = max(limit, 0)
        let effectivePreviewLength = max(previewLength, 1)
        return queue.sync {
            var bindings: [Binding] = [.int(effectivePreviewLength), .text(ftsQuery)]
            bindings.append(contentsOf: terms.map { .text(Self.likePattern(for: $0)) })
            bindings.append(.int(effectiveLimit))
            return queryClips("""
                SELECT c.data_hash, c.data_path, substr(c.title, 1, ?), c.primary_type, c.update_time, c.thumbnail_path, c.is_color_code
                FROM clips c
                WHERE c.rowid IN (
                    SELECT rowid FROM clips_fts WHERE clips_fts MATCH ?
                )
                OR (\(likeClauses))
                ORDER BY c.update_time \(order)
                LIMIT ?
                """,
                bindings)
        }
    }

    func deleteClip(_ clip: CPYClip) {
        queue.sync {
            execute("DELETE FROM clips WHERE data_hash = ?", [.text(clip.dataHash)])
            trimClipDataCache(removedHash: clip.dataHash)
        }
        if !clip.thumbnailPath.isEmpty {
            PINCache.shared.removeObject(forKey: clip.thumbnailPath)
        }
        try? FileManager.default.removeItem(atPath: clip.dataPath)
    }

    func touchClip(_ clip: CPYClip) {
        queue.sync {
            execute("UPDATE clips SET update_time = ? WHERE data_hash = ?",
                    [.int(Int(Date().timeIntervalSince1970)), .text(clip.dataHash)])
        }
    }

    func deleteAllClips() {
        let paths: [String] = queue.sync {
            let values = strings(sql: "SELECT data_path FROM clips")
            execute("DELETE FROM clips", [])
            clipDataCache.removeAll(keepingCapacity: true)
            clipDataCacheOrder.removeAll(keepingCapacity: true)
            return values
        }
        paths.forEach { try? FileManager.default.removeItem(atPath: $0) }
        PINCache.shared.removeAllObjects()
    }

    func deleteOverflowingClips(maxHistorySize: Int) -> [CPYClip] {
        guard maxHistorySize > 0 else { return [] }
        let clips = queue.sync { () -> [CPYClip] in
            let overflow = queryClips("""
                SELECT data_hash, data_path, title, primary_type, update_time, thumbnail_path, is_color_code
                FROM clips
                WHERE data_hash NOT IN (
                    SELECT data_hash FROM clips ORDER BY update_time DESC LIMIT ?
                )
                """, [.int(maxHistorySize)])
            overflow.forEach {
                execute("DELETE FROM clips WHERE data_hash = ?", [.text($0.dataHash)])
                trimClipDataCache(removedHash: $0.dataHash)
            }
            return overflow
        }
        clips.forEach {
            if !$0.thumbnailPath.isEmpty {
                PINCache.shared.removeObject(forKey: $0.thumbnailPath)
            }
            try? FileManager.default.removeItem(atPath: $0.dataPath)
        }
        return clips
    }

    func clipPayloadPaths() -> Set<String> {
        return queue.sync {
            Set(strings(sql: "SELECT data_path FROM clips").compactMap { ($0 as NSString).lastPathComponent })
        }
    }

    func title(dataHash: String, maxLength: Int) -> String? {
        return queue.sync {
            String.scalar(db,
                          sql: "SELECT substr(title, 1, ?) FROM clips WHERE data_hash = ?",
                          bindings: [.int(max(maxLength, 1)), .text(dataHash)])
        }
    }

    func decodedClipData(for clip: CPYClip) throws -> CPYClipData {
        return try queue.sync {
            if let cached = clipDataCache[clip.dataHash] {
                touchClipDataCache(clip.dataHash)
                return cached
            }
            let path = String.scalar(db,
                                     sql: "SELECT data_path FROM clips WHERE data_hash = ?",
                                     bindings: [.text(clip.dataHash)]) ?? clip.dataPath
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoded = try JSONDecoder().decode(CPYClipData.self, from: data)
            clipDataCache[clip.dataHash] = decoded
            clipDataCacheOrder.append(clip.dataHash)
            while clipDataCacheOrder.count > clipDataCacheLimit {
                let evicted = clipDataCacheOrder.removeFirst()
                clipDataCache.removeValue(forKey: evicted)
            }
            return decoded
        }
    }
}

// MARK: - Snippets
extension SQLiteClipStore {
    func folders() -> [CPYFolder] {
        return queue.sync {
            let folders = queryFolders("SELECT identifier, idx, enable, title FROM folders ORDER BY idx ASC", [])
            folders.forEach { folder in
                folder.snippets = querySnippets("""
                    SELECT identifier, folder_identifier, idx, enable, title, content
                    FROM snippets
                    WHERE folder_identifier = ?
                    ORDER BY idx ASC
                    """, [.text(folder.identifier)])
                folder.snippets.forEach { $0.folder = folder }
            }
            return folders
        }
    }

    func folder(identifier: String) -> CPYFolder? {
        return folders().first { $0.identifier == identifier }
    }

    func snippet(identifier: String) -> CPYSnippet? {
        return queue.sync {
            querySnippets("""
                SELECT identifier, folder_identifier, idx, enable, title, content
                FROM snippets
                WHERE identifier = ?
                LIMIT 1
                """, [.text(identifier)]).first
        }
    }

    func lastFolderIndex() -> Int? {
        return queue.sync {
            Int.optionalScalar(db, sql: "SELECT idx FROM folders ORDER BY idx DESC LIMIT 1")
        }
    }

    func upsertFolder(_ folder: CPYFolder) {
        queue.sync {
            execute("""
                INSERT INTO folders(identifier, idx, enable, title)
                VALUES(?, ?, ?, ?)
                ON CONFLICT(identifier) DO UPDATE SET
                    idx = excluded.idx,
                    enable = excluded.enable,
                    title = excluded.title
                """,
                [.text(folder.identifier), .int(folder.index), .int(folder.enable ? 1 : 0), .text(folder.title)])
            folder.snippets.forEach {
                upsertSnippetLocked($0, folderIdentifier: folder.identifier)
            }
        }
        postSnippetsDidChange()
    }

    func deleteFolder(identifier: String) {
        queue.sync {
            execute("DELETE FROM folders WHERE identifier = ?", [.text(identifier)])
        }
        postSnippetsDidChange()
    }

    func updateFolderIndex(identifier: String, index: Int) {
        queue.sync {
            execute("UPDATE folders SET idx = ? WHERE identifier = ?", [.int(index), .text(identifier)])
        }
        postSnippetsDidChange()
    }

    func upsertSnippet(_ snippet: CPYSnippet, folderIdentifier: String?) {
        queue.sync {
            upsertSnippetLocked(snippet, folderIdentifier: folderIdentifier)
        }
        postSnippetsDidChange()
    }

    func deleteSnippet(identifier: String) {
        queue.sync {
            execute("DELETE FROM snippets WHERE identifier = ?", [.text(identifier)])
        }
        postSnippetsDidChange()
    }

    func removeSnippet(_ identifier: String, fromFolderIdentifier folderIdentifier: String) {
        queue.sync {
            execute("DELETE FROM snippets WHERE identifier = ? AND folder_identifier = ?",
                    [.text(identifier), .text(folderIdentifier)])
        }
        postSnippetsDidChange()
    }

    func moveSnippet(_ identifier: String, toFolderIdentifier folderIdentifier: String, index: Int) {
        queue.sync {
            execute("UPDATE snippets SET folder_identifier = ?, idx = ? WHERE identifier = ?",
                    [.text(folderIdentifier), .int(index), .text(identifier)])
        }
        postSnippetsDidChange()
    }

    func updateSnippetIndex(identifier: String, index: Int) {
        queue.sync {
            execute("UPDATE snippets SET idx = ? WHERE identifier = ?", [.int(index), .text(identifier)])
        }
        postSnippetsDidChange()
    }
}

// MARK: - Internals
private extension SQLiteClipStore {
    enum Binding {
        case int(Int)
        case text(String)
    }

    func open() {
        let folder = CPYUtilities.sqliteApplicationSupportFolder()
        _ = CPYUtilities.prepareSaveToPath(folder)
        let path = (folder as NSString).appendingPathComponent("Clipy.sqlite3")
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            lError("Cannot open SQLite store:", lastError)
        }
        execute("PRAGMA journal_mode = WAL", [])
        execute("PRAGMA synchronous = NORMAL", [])
        execute("PRAGMA temp_store = MEMORY", [])
        execute("PRAGMA foreign_keys = ON", [])
    }

    func migrate() {
        execute("""
            CREATE TABLE IF NOT EXISTS clips(
                data_hash TEXT PRIMARY KEY NOT NULL,
                data_path TEXT NOT NULL,
                title TEXT NOT NULL,
                primary_type TEXT NOT NULL,
                update_time INTEGER NOT NULL,
                thumbnail_path TEXT NOT NULL DEFAULT '',
                is_color_code INTEGER NOT NULL DEFAULT 0
            )
            """, [])
        execute("CREATE INDEX IF NOT EXISTS idx_clips_update_time ON clips(update_time DESC)", [])
        execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS clips_fts
            USING fts5(title, content='clips', content_rowid='rowid')
            """, [])
        execute("""
            CREATE TRIGGER IF NOT EXISTS clips_ai AFTER INSERT ON clips BEGIN
                INSERT INTO clips_fts(rowid, title) VALUES (new.rowid, new.title);
            END
            """, [])
        execute("""
            CREATE TRIGGER IF NOT EXISTS clips_ad AFTER DELETE ON clips BEGIN
                INSERT INTO clips_fts(clips_fts, rowid, title) VALUES('delete', old.rowid, old.title);
            END
            """, [])
        execute("""
            CREATE TRIGGER IF NOT EXISTS clips_au AFTER UPDATE ON clips BEGIN
                INSERT INTO clips_fts(clips_fts, rowid, title) VALUES('delete', old.rowid, old.title);
                INSERT INTO clips_fts(rowid, title) VALUES (new.rowid, new.title);
            END
            """, [])
        execute("""
            CREATE TABLE IF NOT EXISTS folders(
                identifier TEXT PRIMARY KEY NOT NULL,
                idx INTEGER NOT NULL,
                enable INTEGER NOT NULL,
                title TEXT NOT NULL
            )
            """, [])
        execute("""
            CREATE TABLE IF NOT EXISTS snippets(
                identifier TEXT PRIMARY KEY NOT NULL,
                folder_identifier TEXT,
                idx INTEGER NOT NULL,
                enable INTEGER NOT NULL,
                title TEXT NOT NULL,
                content TEXT NOT NULL,
                FOREIGN KEY(folder_identifier) REFERENCES folders(identifier) ON DELETE CASCADE
            )
            """, [])
        execute("CREATE INDEX IF NOT EXISTS idx_folders_idx ON folders(idx ASC)", [])
        execute("CREATE INDEX IF NOT EXISTS idx_snippets_folder_idx ON snippets(folder_identifier, idx ASC)", [])
        backfillFileURLTitles()
    }

    func backfillFileURLTitles() {
        var statement: OpaquePointer?
        let sql = """
            SELECT data_hash, title
            FROM clips
            WHERE primary_type = ? AND title LIKE 'file:%'
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            lError("SQLite prepare failed:", sql, lastError)
            return
        }
        defer { sqlite3_finalize(statement) }
        bind([.text(NSPasteboard.PasteboardType.fileURL.rawValue)], to: statement)

        var updates = [(dataHash: String, title: String)]()
        while sqlite3_step(statement) == SQLITE_ROW {
            let dataHash = text(statement, 0)
            let oldTitle = text(statement, 1)
            let newTitle = CPYClipData.fileDisplayTitle(from: oldTitle)
            if newTitle.isNotEmpty, newTitle != oldTitle {
                updates.append((dataHash, newTitle))
            }
        }

        updates.forEach {
            execute("UPDATE clips SET title = ? WHERE data_hash = ?", [.text($0.title), .text($0.dataHash)])
        }
    }

    func execute(_ sql: String, _ bindings: [Binding]) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            lError("SQLite prepare failed:", sql, lastError)
            return
        }
        defer { sqlite3_finalize(statement) }
        bind(bindings, to: statement)
        if sqlite3_step(statement) != SQLITE_DONE {
            lError("SQLite execute failed:", sql, lastError)
        }
    }

    func queryClips(_ sql: String, _ bindings: [Binding]) -> [CPYClip] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            lError("SQLite prepare failed:", sql, lastError)
            return []
        }
        defer { sqlite3_finalize(statement) }
        bind(bindings, to: statement)
        var clips = [CPYClip]()
        while sqlite3_step(statement) == SQLITE_ROW {
            clips.append(CPYClip(dataPath: text(statement, 1),
                                 title: text(statement, 2),
                                 dataHash: text(statement, 0),
                                 primaryType: text(statement, 3),
                                 updateTime: Int(sqlite3_column_int64(statement, 4)),
                                 thumbnailPath: text(statement, 5),
                                 isColorCode: sqlite3_column_int(statement, 6) != 0))
        }
        return clips
    }

    func queryFolders(_ sql: String, _ bindings: [Binding]) -> [CPYFolder] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(bindings, to: statement)
        var folders = [CPYFolder]()
        while sqlite3_step(statement) == SQLITE_ROW {
            folders.append(CPYFolder(index: Int(sqlite3_column_int64(statement, 1)),
                                     enable: sqlite3_column_int(statement, 2) != 0,
                                     title: text(statement, 3),
                                     identifier: text(statement, 0),
                                     snippets: []))
        }
        return folders
    }

    func querySnippets(_ sql: String, _ bindings: [Binding]) -> [CPYSnippet] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(bindings, to: statement)
        var snippets = [CPYSnippet]()
        while sqlite3_step(statement) == SQLITE_ROW {
            snippets.append(CPYSnippet(index: Int(sqlite3_column_int64(statement, 2)),
                                       enable: sqlite3_column_int(statement, 3) != 0,
                                       title: text(statement, 4),
                                       content: text(statement, 5),
                                       identifier: text(statement, 0)))
        }
        return snippets
    }

    func strings(sql: String) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var values = [String]()
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(text(statement, 0))
        }
        return values
    }

    func bind(_ bindings: [Binding], to statement: OpaquePointer?) {
        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch binding {
            case .int(let value):
                sqlite3_bind_int64(statement, position, sqlite3_int64(value))
            case .text(let value):
                sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
            }
        }
    }

    func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    var lastError: String {
        guard let db = db, let message = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: message)
    }

    func upsertSnippetLocked(_ snippet: CPYSnippet, folderIdentifier: String?) {
        execute("""
            INSERT INTO snippets(identifier, folder_identifier, idx, enable, title, content)
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(identifier) DO UPDATE SET
                folder_identifier = excluded.folder_identifier,
                idx = excluded.idx,
                enable = excluded.enable,
                title = excluded.title,
                content = excluded.content
            """,
            [.text(snippet.identifier),
             .text(folderIdentifier ?? snippet.folder?.identifier ?? ""),
             .int(snippet.index),
             .int(snippet.enable ? 1 : 0),
             .text(snippet.title),
             .text(snippet.content)])
    }

    func touchClipDataCache(_ dataHash: String) {
        clipDataCacheOrder.removeAll { $0 == dataHash }
        clipDataCacheOrder.append(dataHash)
    }

    func trimClipDataCache(removedHash: String) {
        clipDataCache.removeValue(forKey: removedHash)
        clipDataCacheOrder.removeAll { $0 == removedHash }
    }

    func postSnippetsDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.snippetsDidChangeNotification, object: self)
        }
    }

    static func searchTerms(for query: String) -> [String] {
        return query
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    static func ftsQuery(for terms: [String]) -> String {
        return terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " ")
    }

    static func likePattern(for term: String) -> String {
        let escaped = term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private extension Int {
    static func scalar(_ db: OpaquePointer?, sql: String, bindings: [SQLiteClipStore.Binding] = []) -> Int {
        return optionalScalar(db, sql: sql, bindings: bindings) ?? 0
    }

    static func optionalScalar(_ db: OpaquePointer?, sql: String, bindings: [SQLiteClipStore.Binding] = []) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        SQLiteClipStore.shared.bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

private extension String {
    static func scalar(_ db: OpaquePointer?, sql: String, bindings: [SQLiteClipStore.Binding] = []) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        SQLiteClipStore.shared.bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }
}
