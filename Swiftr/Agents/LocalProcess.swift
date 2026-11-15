import Darwin
import Foundation

/// Facts about a process on this Mac, read from the kernel.
nonisolated enum LocalProcess {
    /// A process's short name (`zsh`, `Python`...).
    static func processName(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = proc_name(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(count)), as: UTF8.self)
    }

    /// A process's environment (KERN_PROCARGS2, after its arguments), empty
    /// if it can't be read: only a process of the same user's can.
    static func environment(of pid: pid_t) -> [String: String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [:] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [:] }
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var i = MemoryLayout<Int32>.size
        // The executable's path, then padding.
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }
        var strings = 0
        var out: [String: String] = [:]
        while i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            // The arguments, then `KEY=value` strings, until an empty one.
            if i == start { break }
            strings += 1
            if strings > argc {
                let pair = String(decoding: buffer[start ..< i], as: UTF8.self)
                if let eq = pair.firstIndex(of: "=") { out[String(pair[..<eq])] = String(pair[pair.index(after: eq)...]) }
            }
            i += 1
        }
        return out
    }
}
