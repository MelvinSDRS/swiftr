import Foundation
import Observation

/// One machine's `herdr-app` document, read and written with version checks
/// (schema/README.md, "Documents"). Writes run one at a time.
@MainActor @Observable
public final class LayoutSlot {
    public static let documentName = "herdr-app"

    /// The machine as this core names it; nil for this one.
    public nonisolated let machine: String?
    public private(set) var document: LayoutDocument?
    public private(set) var version: Int64 = 0
    public private(set) var error: String?
    public private(set) var loading = false

    @ObservationIgnored private var busy = false
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(machine: String?) {
        self.machine = machine
    }

    public var isReady: Bool { document != nil }

    private func acquire() async {
        while busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
    }

    private func release() {
        busy = false
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    public func reload(_ connection: CoreConnection) async {
        await acquire()
        defer { release() }
        await read(connection)
    }

    /// A document event: reads again when it is newer than what we have.
    public func changed(to version: Int64, _ connection: CoreConnection) async {
        guard version > self.version || document == nil else { return }
        await reload(connection)
    }

    /// Forgets the document (the machine went offline).
    public func reset(error: String?) {
        document = nil
        version = 0
        self.error = error
    }

    private func read(_ connection: CoreConnection) async {
        if document == nil { loading = true }
        defer { loading = false }
        do {
            let r = try await connection.call("doc.get", ["name": .string(Self.documentName), "on": JSON(machine)])
            let v = r["version"]?.int64 ?? 0
            if document == nil || v != version {
                document = LayoutDocument(r["value"])
                version = v
            }
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }

    /// Edits the document and writes it. On a conflict it reads it again and
    /// edits that, so an edit made elsewhere meanwhile is kept. `edit`
    /// returns false when there is nothing to change.
    @discardableResult
    public func update(_ connection: CoreConnection, _ edit: (inout LayoutDocument) -> Bool) async throws -> Bool {
        await acquire()
        defer { release() }
        if document == nil { await read(connection) }
        for _ in 0 ..< 6 {
            guard var doc = document else {
                throw CoreError(kind: "unavailable", message: error ?? "This machine's layout is unavailable.")
            }
            guard edit(&doc) else { return false }
            do {
                let r = try await connection.call("doc.set", ["name": .string(Self.documentName), "on": JSON(machine), "version": .int(version), "value": doc.raw])
                document = doc
                version = r["version"]?.int64 ?? version + 1
                return true
            } catch let e as CoreError where e.kind == "conflict" {
                await read(connection)
            }
        }
        throw CoreError(kind: "conflict", message: "The layout kept changing elsewhere; try again.")
    }
}
