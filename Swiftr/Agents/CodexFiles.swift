import Darwin
import Foundation

/// Where a Codex running on this Mac writes its conversation:
/// `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<thread id>.jsonl`.
nonisolated enum CodexFiles {
    /// `$CODEX_HOME`, else `~/.codex`.
    static var home: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
    }

    /// The session file of the Codex running as `pid` in `cwd`: the one it
    /// holds open (`codex --no-daemon` writes its own), else the newest
    /// written since it started for that folder (a shared Codex server writes
    /// them for it).
    static func session(pid: Int, cwd: String) -> String? {
        let open = openRollouts(pid: pid).filter { !isSubagent(URL(filePath: $0)) }
        // Started last: a new chat (/new) after the first.
        if let newest = open.max(by: { ($0 as NSString).lastPathComponent < ($1 as NSString).lastPathComponent }) { return newest }
        return newestRollout(cwd: cwd, since: startTime(pid: pid))
    }

    /// A shell line that prints the session file of the Codex running as
    /// `pid` on another machine, found as `session(pid:cwd:)` finds it here:
    /// the newest it holds open (`/proc`, else `lsof`), else the newest for
    /// `cwd` written since it started. Sub-agents' threads aside.
    static func remoteLookup(pid: Int, cwd: String) -> String {
        // The folder as the file's first line writes it, in single quotes.
        let json = cwd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let key = "'" + "\"cwd\":\"\(json)\"".replacingOccurrences(of: "'", with: "'\\''") + "'"
        return #"""
        P=\#(pid); K=\#(key); H="${CODEX_HOME:-$HOME/.codex}"
        own() { while IFS= read -r f; do case "$f" in */sessions/*/rollout-*.jsonl) head -c 4096 "$f" 2>/dev/null | grep -q '"source":{"subagent"' || printf '%s\n' "$f";; esac; done; }
        O=$(if [ -d /proc/$P/fd ]; then for f in /proc/$P/fd/*; do readlink "$f"; done 2>/dev/null; else lsof -p $P -Fn 2>/dev/null | sed -n 's/^n//p'; fi | own | sort -u | tail -n 1)
        if [ -n "$O" ]; then printf '%s\n' "$O"; exit 0; fi
        E=$(ps -o etimes= -p $P 2>/dev/null | tr -d ' ')
        [ -n "$E" ] || E=$(ps -o etime= -p $P 2>/dev/null | awk '{d=0; t=$1; if (index(t, "-")) { split(t, x, "-"); d=x[1]; t=x[2] } n=split(t, a, ":"); s=0; for (i=1; i<=n; i++) s=s*60+a[i]; print d*86400+s}')
        case "$E" in ''|*[!0-9]*) exit 0;; esac
        L=$(find "$H/sessions" -name 'rollout-*.jsonl' -mmin -$((E / 60 + 2)) 2>/dev/null | own | while IFS= read -r f; do head -c 4096 "$f" | grep -qF "$K" && printf '%s\n' "$f"; done)
        [ -n "$L" ] && printf '%s\n' "$L" | tr '\n' '\0' | xargs -0 ls -t 2>/dev/null | head -n 1
        """#
    }

    /// The session file whose name ends with `part` (`…-<thread>.jsonl`, or
    /// `…-<thread>_<part>.jsonl` once the person went back to an earlier
    /// message): first beside `near`, then anywhere under `sessions`.
    static func rollout(part: String, near: String) -> String? {
        let suffix = part + ".jsonl"
        let fm = FileManager.default
        let dir = (near as NSString).deletingLastPathComponent
        if let name = (try? fm.contentsOfDirectory(atPath: dir))?.first(where: { $0.hasPrefix("rollout-") && $0.hasSuffix(suffix) }) {
            return (dir as NSString).appendingPathComponent(name)
        }
        let root = home.appending(path: "sessions")
        guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in walk where url.lastPathComponent.hasPrefix("rollout-") && url.lastPathComponent.hasSuffix(suffix) {
            return url.path
        }
        return nil
    }

    /// A shell line that prints, on another machine, the path of the
    /// session file whose name ends with `part` and the `ordinal` of its
    /// first line, one per line.
    static func remoteRollout(part: String) -> String {
        let safe = part.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return #"""
        H="${CODEX_HOME:-$HOME/.codex}"; F=$(find "$H/sessions" -name 'rollout-*\#(safe).jsonl' 2>/dev/null | head -n 1)
        [ -n "$F" ] || exit 0; printf '%s\n' "$F"; head -c 200 "$F" | grep -o '"ordinal":[0-9]*' | head -n 1 | cut -d: -f2
        """#
    }

    /// `rollout-2026-11-12T00-52-18-01a1ce50-68b4-70f2-8b0d-ac4950b83911.jsonl` → its thread id.
    static func threadID(_ path: String) -> String {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return name.count > 36 ? String(name.suffix(36)) : name
    }

    static func isRollout(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return path.contains("/sessions/") && name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }

    /// The session files among a process's open files.
    static func openRollouts(pid: Int) -> [String] {
        let pid = Int32(pid)
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 8)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        var out: [String] = []
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if isRollout(path), !out.contains(path) { out.append(path) }
        }
        return out
    }

    /// When the process started.
    static func startTime(pid: Int) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec))
    }

    /// The newest session file of today's or yesterday's written since
    /// `since` for `cwd`, sub-agents' aside.
    static func newestRollout(cwd: String, since: Date?) -> String? {
        let calendar = Calendar.current
        var best: (path: String, date: Date)?
        for back in 0 ... 1 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            guard let y = c.year, let m = c.month, let d = c.day else { continue }
            let dir = home.appending(path: String(format: "sessions/%04d/%02d/%02d", y, m, d))
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                let url = dir.appending(path: name)
                guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
                if let since, date < since.addingTimeInterval(-2) { continue }
                if let best, best.date >= date { continue }
                let head = Self.head(url)
                guard Self.cwd(in: head) == cwd, !head.contains("\"source\":{\"subagent\"") else { continue }
                best = (url.path, date)
            }
        }
        return best?.path
    }

    /// A sub-agent's thread (`"source":{"subagent":…}` in its first line).
    static func isSubagent(_ url: URL) -> Bool {
        head(url).contains("\"source\":{\"subagent\"")
    }

    /// The folder a session file's first line names.
    static func cwd(in head: String) -> String? {
        guard let r = head.range(of: "\"cwd\":\"") else { return nil }
        var out = ""
        var escaped = false
        for ch in head[r.upperBound...] {
            if escaped {
                out.append(ch == "/" ? "/" : ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                return out
            } else {
                out.append(ch)
            }
        }
        return nil
    }

    /// A file's first bytes, where its first line says what the session is.
    private static func head(_ url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        return String(decoding: (try? h.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
    }
}
