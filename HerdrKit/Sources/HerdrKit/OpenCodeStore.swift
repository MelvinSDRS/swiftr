import Foundation
import SQLite3

/// OpenCode's database (2.x): `$XDG_DATA_HOME/opencode/opencode.db`, else
/// `~/.local/share/opencode/opencode.db`. Its server (the background
/// service, or a TUI's own with `--standalone`) writes the sessions there,
/// a row per message; Swiftr only reads it.
public enum OpenCodeStore {
    public static var database: URL {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_DATA_HOME"].map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/share")
        return base.appending(path: "opencode/opencode.db")
    }

    /// The session an OpenCode started with `argv` in `directory` shows: the
    /// one `--session` names; else the newest top-level session there, the
    /// last one with `--continue`, or one changed since the program started.
    public static func session(argv: [String], directory: String, started: Date?, db: URL = database) -> String? {
        guard let reader = try? SQLiteReader(db) else { return nil }
        if let i = argv.firstIndex(where: { $0 == "--session" || $0 == "-s" }), i + 1 < argv.count {
            return argv[i + 1]
        }
        if let named = argv.first(where: { $0.hasPrefix("--session=") }) {
            return String(named.dropFirst("--session=".count))
        }
        let continues = argv.contains { $0 == "--continue" || $0 == "-c" }
        // A little before the start: the first message can come with it (`--prompt`).
        let since = continues ? 0 : Int64(((started?.timeIntervalSince1970 ?? 0) - 2) * 1000)
        let rows = try? reader.rows(
            "select id from session_v2 where directory = ? and parent_id is null and time_archived is null and time_updated >= ? order by time_updated desc limit 1",
            [.text(directory), .int(since)]
        )
        return rows?.first?.first?.text
    }

    /// A session's title, as OpenCode names it.
    public static func title(of session: String, db: URL = database) -> String? {
        guard let reader = try? SQLiteReader(db) else { return nil }
        return (try? reader.rows("select title from session_v2 where id = ?", [.text(session)]))?.first?.first?.text
    }
}

/// One session's rows, read in order of `seq`, as the lines
/// `Transcript.readOpenCode` reads. A row read before that changes (a tool
/// done, a step finished) makes `readNew` ask for the session again.
public actor OpenCodeTranscript: TranscriptSource {
    public let db: URL
    public let session: String
    private var reader: SQLiteReader?
    /// The first and last rows read.
    private var first: Int64?
    private var last: Int64 = -1
    /// The newest change among the rows read, in ms.
    private var changed: Int64 = 0
    private var start = true
    /// "provider/model" → its name, context and provider's name, from OpenCode's catalog.
    private var models: [String: Model] = [:]
    /// The session's revert under way (`session_v2.revert`), as last read.
    private var revertMark: String?
    /// Its message's place, and the line that says so: rows from there on
    /// are out of sight until OpenCode undoes the revert or ends it.
    private var revert: (seq: Int64, line: Data)?

    private struct Model {
        var name: String?
        var window: Int?
        var provider: String?
    }

    public init(db: URL = OpenCodeStore.database, session: String) {
        self.db = db
        self.session = session
    }

    public var atStart: Bool { start }

    private func open() throws -> SQLiteReader {
        if let reader { return reader }
        let r = try SQLiteReader(db)
        reader = r
        return r
    }

    private static let columns = "id, seq, type, time_updated, data, json_extract(data, '$.model.providerID'), json_extract(data, '$.model.id')"

    public func openTail(lines: Int, maxBytes: Int) async throws -> [Data] {
        let r = try open()
        readRevert(r)
        var rows = try r.rows("select \(Self.columns) from session_message where session_id = ? and seq < ? order by seq desc limit ?",
                              [.text(session), .int(revert?.seq ?? Int64.max), .int(Int64(lines))])
        rows.reverse()
        // The newest rows that fit.
        var bytes = 0
        var keep = rows.count
        for (i, row) in rows.enumerated().reversed() {
            bytes += row[4].text?.utf8.count ?? 0
            if bytes > maxBytes, i < rows.count - 1 { break }
            keep = rows.count - i
        }
        rows = Array(rows.suffix(keep))
        first = rows.first?[1].int
        last = rows.last?[1].int ?? -1
        changed = rows.compactMap { $0[3].int }.max() ?? 0
        if let first {
            start = (try r.rows("select 1 from session_message where session_id = ? and seq < ? limit 1", [.text(session), .int(first)])).isEmpty
        } else {
            start = true
        }
        return rows.map(line) + (revert.map { [$0.line] } ?? [])
    }

    public func readNew() async throws -> [Data]? {
        let r = try open()
        // A revert made, undone (`/redo`) or ended by the next message: the session is read again.
        if Self.revertMark(r, session) != revertMark { return nil }
        let rows = try r.rows(
            "select \(Self.columns) from session_message where session_id = ? and seq < ? and (seq > ? or time_updated > ?) order by seq",
            [.text(session), .int(revert?.seq ?? Int64.max), .int(last), .int(changed)]
        )
        guard !rows.isEmpty else { return [] }
        // A row already read changed: the session is read again.
        if rows.contains(where: { ($0[1].int ?? 0) <= last }) { return nil }
        last = rows.last?[1].int ?? last
        changed = max(changed, rows.compactMap { $0[3].int }.max() ?? 0)
        if first == nil { first = rows.first?[1].int }
        return rows.map(line)
    }

    public func readEarlier(lines: Int, maxBytes: Int) async throws -> [Data] {
        guard let first else { return [] }
        let r = try open()
        var rows = try r.rows("select \(Self.columns) from session_message where session_id = ? and seq < ? order by seq desc limit ?", [.text(session), .int(first), .int(Int64(lines))])
        rows.reverse()
        start = rows.count < lines
        self.first = rows.first?[1].int ?? first
        return rows.map(line)
    }

    /// The session's `revert`; nil without one, or in a database older than it.
    private static func revertMark(_ r: SQLiteReader, _ session: String) -> String? {
        (try? r.rows("select revert from session_v2 where id = ?", [.text(session)]))?.first?.first?.text
    }

    /// Reads the revert under way, if any: `{"messageID":…,"files":[…]}`.
    /// Its message and the rows after it go out of sight; a line in their
    /// place says how many of the person's messages went, and the files.
    private func readRevert(_ r: SQLiteReader) {
        let mark = Self.revertMark(r, session)
        revertMark = mark
        revert = nil
        guard let mark, let o = try? JSONSerialization.jsonObject(with: Data(mark.utf8)) as? [String: Any],
              let id = o["messageID"] as? String,
              let seq = (try? r.rows("select seq from session_message where session_id = ? and id = ?", [.text(session), .text(id)]))?.first?.first?.int
        else { return }
        let messages = (try? r.rows("select count(*) from session_message where session_id = ? and type = 'user' and seq >= ?",
                                    [.text(session), .int(seq)]))?.first?.first?.int ?? 0
        let body: [String: Any] = ["messages": messages, "files": o["files"] as? [[String: Any]] ?? []]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var out = Data("{\"id\":".utf8)
        out += Self.quoted("reverted-" + id)
        out += Data(",\"seq\":\(seq),\"type\":\"reverted\",\"data\":".utf8)
        out += data
        out += Data("}".utf8)
        revert = (seq, out)
    }

    /// `{"id":…,"seq":…,"type":…,"window":…,"modelName":…,"providerName":…,"data":<the row's JSON>}`.
    private func line(_ row: [SQLiteReader.Value]) -> Data {
        var out = Data("{\"id\":".utf8)
        out += Self.quoted(row[0].text ?? "")
        out += Data(",\"seq\":\(row[1].int ?? 0),\"type\":".utf8)
        out += Self.quoted(row[2].text ?? "")
        if let provider = row[5].text, let modelID = row[6].text {
            let info = model(provider: provider, id: modelID)
            if let window = info.window { out += Data(",\"window\":\(window)".utf8) }
            if let name = info.name {
                out += Data(",\"modelName\":".utf8)
                out += Self.quoted(name)
            }
            if let provider = info.provider {
                out += Data(",\"providerName\":".utf8)
                out += Self.quoted(provider)
            }
        }
        out += Data(",\"data\":".utf8)
        out += Data((row[4].text ?? "{}").utf8)
        out += Data("}".utf8)
        return out
    }

    /// A model's name and context, and its provider's name, from the
    /// catalog OpenCode keeps (models.dev's, in `kv`).
    private func model(provider: String, id: String) -> Model {
        let key = provider + "/" + id
        if let known = models[key] { return known }
        var found = Model()
        // The catalog is one large JSON text: SQLite reads the values out of it.
        let at = "$.\"\(provider.replacingOccurrences(of: "\"", with: ""))\""
        let path = at + ".models.\"\(id.replacingOccurrences(of: "\"", with: ""))\""
        if let r = try? open(),
           let row = (try? r.rows(
               "with c(body) as (select json_extract(value, '$.body') from kv where key = 'models-dev:v2:catalog') select json_extract(body, ?), json_extract(body, ?), json_extract(body, ?) from c",
               [.text(path + ".name"), .text(path + ".limit.context"), .text(at + ".name")]
           ))?.first
        {
            found = Model(name: row[0].text, window: row[1].int.map(Int.init), provider: row[2].text)
        }
        models[key] = found
        return found
    }

    private static func quoted(_ s: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed])) ?? Data("\"\"".utf8)
    }
}

// MARK: - SQLite

/// A read-only connection to a SQLite database, for a few queries.
final class SQLiteReader: @unchecked Sendable {
    enum Value: Sendable {
        case null
        case int(Int64)
        case real(Double)
        case text(String)

        var text: String? {
            switch self {
            case .text(let s): s
            case .int(let n): String(n)
            case .real(let d): String(d)
            case .null: nil
            }
        }

        var int: Int64? {
            switch self {
            case .int(let n): n
            case .real(let d): Int64(d)
            case .text(let s): Int64(s)
            case .null: nil
            }
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private var handle: OpaquePointer?

    init(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure(description: "No database at \(url.path)") }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(db)
            throw Failure(description: message)
        }
        // OpenCode writes while this reads: wait a little for its lock.
        sqlite3_busy_timeout(db, 1000)
        handle = db
    }

    deinit {
        sqlite3_close(handle)
    }

    func rows(_ sql: String, _ arguments: [Value] = []) throws -> [[Value]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(description: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, argument) in arguments.enumerated() {
            let at = Int32(i + 1)
            switch argument {
            case .null: sqlite3_bind_null(statement, at)
            case .int(let n): sqlite3_bind_int64(statement, at, n)
            case .real(let d): sqlite3_bind_double(statement, at, d)
            case .text(let s): sqlite3_bind_text(statement, at, s, -1, transient)
            }
        }
        var out: [[Value]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw Failure(description: String(cString: sqlite3_errmsg(handle))) }
            var row: [Value] = []
            for c in 0 ..< sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, c) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(statement, c)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, c)))
                case SQLITE_NULL: row.append(.null)
                default:
                    if let text = sqlite3_column_text(statement, c) {
                        row.append(.text(String(cString: text)))
                    } else {
                        row.append(.null)
                    }
                }
            }
            out.append(row)
        }
        return out
    }
}
