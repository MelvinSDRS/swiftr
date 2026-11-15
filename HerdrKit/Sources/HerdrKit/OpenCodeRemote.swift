import Foundation

/// OpenCode on another machine. A short Python program, run there with
/// `machine.exec`, reads its sessions where OpenCode keeps them: in its
/// database (2.x, `opencode.db`) or as JSON files (1.x, `storage/`, a file
/// per message and per part). It prints what it read as JSON lines; this
/// turns them into the rows `Transcript.readOpenCode` reads.
public enum OpenCodeRemote {
    /// What the program printed.
    public struct Output: Sendable {
        public var rows: [Row] = []
        /// "provider/model" → its name, context and provider's name.
        public var models: [String: Model] = [:]
        /// Nothing comes before the rows read.
        public var start: Bool?
        public var session: String?
        public var title: String?
        public var error: String?
        /// The program ran to its end (else Python is missing, or failed).
        public var done = false
        /// The session's revert under way, as OpenCode keeps it; nil without one.
        public var revertMark: String?
        /// The line that stands for what it took out of sight.
        public var revertLine: Data?
    }

    public struct Row: Sendable {
        public var seq: Int64
        /// Its last change, in ms.
        public var updated: Int64
        /// The rows `Transcript.readOpenCode` reads (an OpenCode 1.x
        /// message may give two: its step, then its turn's end).
        public var lines: [Data]
    }

    public struct Model: Sendable, Equatable {
        public var name: String?
        public var window: Int?
        public var provider: String?
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// The shell line that runs the program there with `arguments`; `base`
    /// is OpenCode's data folder, nil for its own default.
    public static func line(base: String?, _ arguments: [String]) -> String {
        (["python3", "-c", script, base ?? ""] + arguments).map(AgentLaunch.quoted).joined(separator: " ")
    }

    /// The session an OpenCode started with `argv` shows: the one
    /// `--session` names, else nil (the program then looks for it).
    public static func named(in argv: [String]) -> String? {
        if let i = argv.firstIndex(where: { $0 == "--session" || $0 == "-s" }), i + 1 < argv.count { return argv[i + 1] }
        return argv.first { $0.hasPrefix("--session=") }.map { String($0.dropFirst("--session=".count)) }
    }

    /// The program's arguments to find the session an OpenCode started with
    /// `argv` in `directory` shows: the newest one there changed since it
    /// started, or the last one with `--continue`.
    public static func findArguments(argv: [String], directory: String, pid: Int) -> [String] {
        let continues = argv.contains { $0 == "--continue" || $0 == "-c" }
        return ["find", directory, String(pid), continues ? "1" : "0"]
    }

    /// Reads what the program printed.
    public static func read(_ output: Data) -> Output {
        var out = Output()
        var pending: [(row: [String: Any], seq: Int64, updated: Int64)] = []
        for line in output.split(separator: 0x0A) where !line.isEmpty {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            if let row = o["row"] as? [Any] {
                pending.append((["row": row], int(row.count > 1 ? row[1] : nil) ?? 0, int(row.count > 3 ? row[3] : nil) ?? 0))
            } else if o["message"] != nil {
                pending.append((o, int(o["seq"]) ?? 0, int(o["updated"]) ?? 0))
            } else if let key = o["model"] as? String {
                out.models[key] = Model(name: o["name"] as? String, window: int(o["window"]).map(Int.init), provider: o["provider"] as? String)
            } else if let start = o["start"] as? Bool {
                out.start = start
            } else if o["done"] != nil {
                out.done = true
            } else if let error = o["error"] as? String {
                out.error = error
            } else if o.keys.contains("revert") {
                out.revertMark = o["revert"] as? String
                if let id = o["revertID"] as? String,
                   let body = try? JSONSerialization.data(withJSONObject: ["messages": int(o["messages"]) ?? 0, "files": o["files"] as? [Any] ?? []])
                {
                    out.revertLine = Self.line(id: "reverted-" + id, seq: int(o["revertSeq"]) ?? 0, type: "reverted", data: body, model: nil)
                }
            } else if o.keys.contains("session") {
                out.session = o["session"] as? String
                out.title = o["title"] as? String
            }
        }
        out.rows = pending.map { p in
            Row(seq: p.seq, updated: p.updated, lines: lines(p.row, models: out.models))
        }
        return out
    }

    /// One printed row as the lines `Transcript.readOpenCode` reads.
    static func lines(_ o: [String: Any], models: [String: Model]) -> [Data] {
        if let row = o["row"] as? [Any], row.count >= 5 {
            // 2.x: id, seq, type, time_updated, data, providerID, modelID.
            let provider = row.count > 5 ? row[5] as? String : nil
            let modelID = row.count > 6 ? row[6] as? String : nil
            let info = provider.flatMap { p in modelID.flatMap { models[p + "/" + $0] } }
            let data = (row[4] as? String).map { Data($0.utf8) } ?? Data("{}".utf8)
            return [line(id: row[0] as? String ?? "", seq: int(row[1]) ?? 0, type: row[2] as? String ?? "", data: data, model: info)]
        }
        guard let message = o["message"] as? [String: Any] else { return [] }
        let parts = o["parts"] as? [[String: Any]] ?? []
        let seq = int(o["seq"]) ?? 0
        let id = message["id"] as? String ?? "msg-\(seq)"
        let key = (message["providerID"] as? String).flatMap { p in (message["modelID"] as? String).map { p + "/" + $0 } }
        return filesRows(message: message, parts: parts).compactMap { type, data in
            guard let body = try? JSONSerialization.data(withJSONObject: data) else { return nil }
            return line(id: type == "idle" ? id + "/idle" : id, seq: seq, type: type, data: body, model: type == "assistant" ? key.flatMap { models[$0] } : nil)
        }
    }

    /// `{"id":…,"seq":…,"type":…,"window":…,"modelName":…,"providerName":…,"data":…}`.
    static func line(id: String, seq: Int64, type: String, data: Data, model: Model?) -> Data {
        var out = Data("{\"id\":".utf8)
        out += quoted(id)
        out += Data(",\"seq\":\(seq),\"type\":".utf8)
        out += quoted(type)
        if let window = model?.window { out += Data(",\"window\":\(window)".utf8) }
        if let name = model?.name {
            out += Data(",\"modelName\":".utf8)
            out += quoted(name)
        }
        if let provider = model?.provider {
            out += Data(",\"providerName\":".utf8)
            out += quoted(provider)
        }
        out += Data(",\"data\":".utf8)
        out += data
        out += Data("}".utf8)
        return out
    }

    /// OpenCode 1.x's message (its info, and its parts in order) as the rows
    /// 2.x keeps: `user`, or an `assistant` step, then `idle` when its turn
    /// ended there.
    static func filesRows(message m: [String: Any], parts: [[String: Any]]) -> [(type: String, data: [String: Any])] {
        let time = m["time"] as? [String: Any] ?? [:]
        switch m["role"] as? String {
        case "user":
            // What the person wrote; OpenCode's own texts (a file read for them) are `synthetic`.
            let texts = parts.filter { $0["type"] as? String == "text" && $0["synthetic"] as? Bool != true && $0["ignored"] as? Bool != true }
                .compactMap { $0["text"] as? String }
            let files = parts.filter { $0["type"] as? String == "file" }.map { ["mime": $0["mime"] as? String ?? ""] }
            return [("user", ["text": texts.joined(separator: "\n"), "files": files, "time": time])]
        case "assistant":
            var content: [[String: Any]] = []
            for p in parts {
                switch p["type"] as? String {
                case "text": content.append(["type": "text", "text": p["text"] as? String ?? ""])
                case "reasoning": content.append(["type": "reasoning", "text": p["text"] as? String ?? ""])
                case "tool":
                    var state = p["state"] as? [String: Any] ?? [:]
                    if let output = state["output"] as? String { state["content"] = [["type": "text", "text": output]] }
                    // 1.x says it in its own words (`Error: The user rejected permission…`).
                    if let error = state["error"] as? String, error.contains("The user rejected permission") {
                        state["error"] = Transcript.openCodeDeclined
                    }
                    content.append(["type": "tool", "id": p["callID"] as? String ?? p["id"] as? String ?? "", "name": p["tool"] as? String ?? "tool", "state": state])
                default:
                    continue
                }
            }
            var data: [String: Any] = ["content": content, "time": time]
            if let model = m["modelID"] as? String { data["model"] = ["id": model, "providerID": m["providerID"] as? String ?? ""] }
            if let agent = m["agent"] as? String ?? m["mode"] as? String { data["agent"] = agent }
            if let tokens = m["tokens"] { data["tokens"] = tokens }
            if let error = m["error"] as? [String: Any] {
                if error["name"] as? String == "MessageAbortedError" {
                    data["error"] = ["type": "aborted"]
                } else {
                    data["error"] = ["message": (error["data"] as? [String: Any])?["message"] as? String ?? error["name"] as? String ?? "Error"]
                }
            }
            var rows: [(type: String, data: [String: Any])] = [("assistant", data)]
            if m["finish"] as? String == "stop", let completed = time["completed"] {
                rows.append(("idle", ["outcome": "succeeded", "time": ["created": completed]]))
            }
            return rows
        default:
            return []
        }
    }

    private static func quoted(_ s: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed])) ?? Data("\"\"".utf8)
    }

    static func int(_ value: Any?) -> Int64? {
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String { return Int64(s) }
        return nil
    }

    /// Run as `python3 -c <script> <base> <mode> <arguments…>`, base "" for
    /// OpenCode's default folder:
    ///
    /// - `find <directory> <pid> <continue 0|1>`: the newest top-level
    ///   session in that folder changed since that process started (any
    ///   time, with continue), and its title.
    /// - `tail <session> <n>`, `new <session> <last seq> <last change ms>`,
    ///   `earlier <session> <first seq> <n>`: rows, then the models they name.
    ///
    /// It ends with `{"done":true}`.
    public static let script = #"""
    import glob, json, os, sqlite3, subprocess, sys, time
    base, mode, args = sys.argv[1], sys.argv[2], sys.argv[3:]
    if not base:
        base = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "opencode")
    db = os.path.join(base, "opencode.db")
    store = os.path.join(base, "storage")

    def emit(o):
        sys.stdout.write(json.dumps(o, separators=(",", ":")) + "\n")

    def load(path):
        try:
            with open(path) as f:
                return json.load(f)
        except Exception:
            return None

    def started(pid):
        for key in ("etimes=", "etime="):
            try:
                out = subprocess.check_output(["ps", "-o", key, "-p", pid], stderr=subprocess.DEVNULL).decode().strip()
                days, _, rest = out.rpartition("-")
                parts = [int(x) for x in rest.split(":")]
                while len(parts) < 3:
                    parts.insert(0, 0)
                return time.time() - ((int(days) if days else 0) * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2])
            except Exception:
                pass
        return 0

    def since():
        return 0 if args[2] == "1" else int((started(args[1]) - 2) * 1000)

    def catalog(keys, find):
        for key in keys:
            provider, _, model = key.partition("/")
            info = find(provider, model)
            if info:
                emit(dict(model=key, name=info[0], window=info[1], provider=info[2]))

    if os.path.exists(db):
        con = sqlite3.connect("file:" + db + "?mode=ro", uri=True, timeout=2)
        q = lambda sql, a=(): con.execute(sql, a).fetchall()
        if mode == "find":
            r = q("select id, title from session_v2 where directory = ? and parent_id is null and time_archived is null and time_updated >= ? order by time_updated desc limit 1", (args[0], since()))
            emit(dict(session=r[0][0] if r else None, title=r[0][1] if r else None))
        else:
            cols = "id, seq, type, time_updated, data, json_extract(data, '$.model.providerID'), json_extract(data, '$.model.id')"
            sid, start = args[0], None
            # A revert under way (the timeline's Revert, /undo): its message and those after it are out of sight.
            try:
                mark = (q("select revert from session_v2 where id = ?", (sid,)) or [[None]])[0][0]
            except Exception:
                mark = None
            info, upto = dict(revert=mark), 2 ** 62
            try:
                rv = json.loads(mark) if mark else None
                r = q("select seq from session_message where session_id = ? and id = ?", (sid, rv["messageID"])) if rv else []
                if r:
                    upto = r[0][0]
                    n = q("select count(*) from session_message where session_id = ? and type = 'user' and seq >= ?", (sid, upto))[0][0]
                    info.update(revertID=rv["messageID"], revertSeq=upto, messages=n, files=rv.get("files") or [])
            except Exception:
                pass
            emit(info)
            if mode == "tail":
                rows = q("select " + cols + " from session_message where session_id = ? and seq < ? order by seq desc limit ?", (sid, upto, int(args[1])))[::-1]
                start = not rows or not q("select 1 from session_message where session_id = ? and seq < ? limit 1", (sid, rows[0][1]))
            elif mode == "new":
                rows = q("select " + cols + " from session_message where session_id = ? and seq < ? and (seq > ? or time_updated > ?) order by seq", (sid, upto, int(args[1]), int(args[2])))
            else:
                rows = q("select " + cols + " from session_message where session_id = ? and seq < ? order by seq desc limit ?", (sid, min(upto, int(args[1])), int(args[2])))[::-1]
                start = len(rows) < int(args[2])
            keys = []
            for r in rows:
                emit(dict(row=list(r)))
                if r[5] and r[6] and r[5] + "/" + r[6] not in keys:
                    keys.append(r[5] + "/" + r[6])
            def find(provider, model):
                at = '$."' + provider.replace('"', "") + '"'
                path = at + '.models."' + model.replace('"', "") + '"'
                r = q("with c(body) as (select json_extract(value, '$.body') from kv where key = 'models-dev:v2:catalog') select json_extract(body, ?), json_extract(body, ?), json_extract(body, ?) from c", (path + ".name", path + ".limit.context", at + ".name"))
                return r[0] if r else None
            catalog(keys, find)
            if start is not None:
                emit(dict(start=start))
    elif os.path.isdir(store):
        if mode == "find":
            best, at = None, since()
            for f in glob.glob(os.path.join(store, "session", "*", "*.json")):
                s = load(f)
                if not s or s.get("directory") != args[0] or s.get("parentID"):
                    continue
                t = (s.get("time") or {}).get("updated") or 0
                if t >= at and (best is None or t > best[0]):
                    best = (t, s.get("id"), s.get("title"))
            emit(dict(session=best[1] if best else None, title=best[2] if best else None))
        else:
            sid, start = args[0], None
            files = sorted(glob.glob(os.path.join(store, "message", sid, "*.json")))
            n = len(files)
            # A revert under way, in the session's file: its message and those after it are out of sight.
            info = dict(revert=None)
            for f in glob.glob(os.path.join(store, "session", "*", sid + ".json")):
                rv = (load(f) or {}).get("revert")
                if rv:
                    info["revert"] = json.dumps(rv, sort_keys=True)
                    ids = [os.path.basename(x)[:-5] for x in files]
                    if rv.get("messageID") in ids:
                        n = ids.index(rv["messageID"])
                        users = sum(1 for x in files[n:] if (load(x) or {}).get("role") == "user")
                        info.update(revertID=rv["messageID"], revertSeq=n, messages=users, files=[])
                break
            emit(info)
            def name(i):
                return os.path.basename(files[i])[:-5]
            def parts(i):
                return sorted(glob.glob(os.path.join(store, "part", name(i), "*.json")))
            def updated(i):
                return int(max([os.path.getmtime(files[i])] + [os.path.getmtime(p) for p in parts(i)]) * 1000)
            if mode == "tail":
                pick = list(range(max(0, n - int(args[1])), n))
                start = not pick or pick[0] == 0
            elif mode == "new":
                last, changed = int(args[1]), int(args[2])
                pick = [i for i in range(max(0, last - 3), n) if i > last or updated(i) > changed]
            else:
                end = min(int(args[1]), n)
                pick = list(range(max(0, end - int(args[2])), end))
                start = not pick or pick[0] == 0
            keys = []
            for i in pick:
                m = load(files[i])
                if m is None:
                    continue
                emit(dict(message=m, parts=[p for p in map(load, parts(i)) if p], seq=i, updated=updated(i)))
                if m.get("providerID") and m.get("modelID") and m["providerID"] + "/" + m["modelID"] not in keys:
                    keys.append(m["providerID"] + "/" + m["modelID"])
            models = load(os.path.expanduser("~/.cache/opencode/models.json")) or {}
            def find(provider, model):
                p = models.get(provider) or {}
                m = (p.get("models") or {}).get(model)
                return (m.get("name"), (m.get("limit") or {}).get("context") or None, p.get("name")) if m else None
            catalog(keys, find)
            if start is not None:
                emit(dict(start=start))
    else:
        emit(dict(error="No OpenCode sessions in " + base))
    emit(dict(done=True))
    """#
}

/// A session of an OpenCode on another machine, read through
/// `OpenCodeRemote`'s program as `OpenCodeTranscript` reads one here.
public actor RemoteOpenCodeTranscript: TranscriptSource {
    /// Runs the program with these arguments there; what it printed.
    public typealias Run = @Sendable (_ arguments: [String]) async throws -> Data

    public let session: String
    private let run: Run
    private var first: Int64?
    private var last: Int64 = -1
    /// The newest change among the rows read, in ms.
    private var changed: Int64 = 0
    private var start = true
    /// The session's revert under way, as last read.
    private var revertMark: String?

    public init(session: String, run: @escaping Run) {
        self.session = session
        self.run = run
    }

    public var atStart: Bool { start }

    private func ask(_ arguments: [String]) async throws -> OpenCodeRemote.Output {
        let out = OpenCodeRemote.read(try await run(arguments))
        if let error = out.error { throw OpenCodeRemote.Failure(description: error) }
        guard out.done else { throw OpenCodeRemote.Failure(description: "OpenCode's sessions can't be read there: it needs python3.") }
        return out
    }

    public func openTail(lines: Int, maxBytes: Int) async throws -> [Data] {
        let out = try await ask(["tail", session, String(lines)])
        // The newest rows that fit.
        var rows = out.rows
        var bytes = 0
        var keep = rows.count
        for (i, row) in rows.enumerated().reversed() {
            bytes += row.lines.reduce(0) { $0 + $1.count }
            if bytes > maxBytes, i < rows.count - 1 { break }
            keep = rows.count - i
        }
        let cut = keep < rows.count
        rows = Array(rows.suffix(keep))
        first = rows.first?.seq
        last = rows.last?.seq ?? -1
        changed = rows.map(\.updated).max() ?? 0
        start = !cut && (out.start ?? true)
        revertMark = out.revertMark
        return rows.flatMap(\.lines) + (out.revertLine.map { [$0] } ?? [])
    }

    public func readNew() async throws -> [Data]? {
        let out = try await ask(["new", session, String(last), String(changed)])
        // A revert made, undone (`/redo`) or ended by the next message: the session is read again.
        if out.revertMark != revertMark { return nil }
        guard !out.rows.isEmpty else { return [] }
        // A row already read changed: the session is read again.
        if out.rows.contains(where: { $0.seq <= last }) { return nil }
        last = out.rows.last?.seq ?? last
        changed = max(changed, out.rows.map(\.updated).max() ?? 0)
        if first == nil { first = out.rows.first?.seq }
        return out.rows.flatMap(\.lines)
    }

    public func readEarlier(lines: Int, maxBytes: Int) async throws -> [Data] {
        guard let first else { return [] }
        let out = try await ask(["earlier", session, String(first), String(lines)])
        start = out.start ?? true
        self.first = out.rows.first?.seq ?? first
        return out.rows.flatMap(\.lines)
    }
}
