import AppKit
import HerdrKit

/// Keeps the layouts and the terminals in step, as herdr-app does
/// (window.rs `reconcile`): a pane whose program ended goes; a live terminal
/// labeled for a space but without a pane gets one. Every edit is checked
/// again on the document it is written to. While herdr-app runs, it does
/// this work for both: Swiftr leaves the documents alone.
extension AppModel {
    /// herdr-app (Herdr.app, `dev.herdr.app`) is running on this Mac and
    /// shows this core (it only uses the default one).
    var herdrAppRunning: Bool {
        endpoint.session == "default" && !NSRunningApplication.runningApplications(withBundleIdentifier: Self.herdrAppID).isEmpty
    }

    func scheduleReconcile() {
        reconcileTask?.cancel()
        reconcileTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await reconcile()
        }
    }

    /// Made by this window less than 5 s ago: the core may not list it yet.
    private func justBorn(_ address: String) -> Bool {
        born = born.filter { $0.value.timeIntervalSinceNow > -30 }
        if let at = born[address], at.timeIntervalSinceNow > -5 { return true }
        if let m = store.model(address), m.createdMs > 0 {
            let age = Date().timeIntervalSince1970 * 1000 - Double(m.createdMs)
            if age < 5000 { return true }
        }
        return false
    }

    private func reconcile() async {
        guard link == .connected, let c = connection, !herdrAppRunning else { return }

        // Panes whose terminal is not live: look closer before removing.
        var missing: [(machine: String, pane: String, address: String)] = []
        for (machine, slot) in slots {
            guard machineReady(machine), let doc = slot.document else { continue }
            for space in doc.spaces {
                for tab in space.tabs {
                    for (pane, t) in tab.root.terminals {
                        let address = qualify(t, on: machine)
                        if store.model(address)?.isLive == true || justBorn(address) || busy.contains(address) { continue }
                        missing.append((machine, pane, address))
                    }
                }
            }
        }
        var changed = false
        for item in missing {
            busy.insert(item.address)
            defer { busy.remove(item.address) }
            // A failed lookup is not evidence the program exited.
            let closed: Bool
            do {
                let r = try await c.call("terminal.get", ["terminal": .string(item.address)])
                closed = r["state"]?.string == "finished" && ["exited", "killed"].contains(r["reason"]?.string ?? "")
            } catch let e as CoreError {
                closed = e.kind == "not_found"
            } catch {
                closed = false
            }
            guard closed, let slot = slots[item.machine] else { continue }
            let local = splitAddress(item.address).local
            let removed = (try? await slot.update(c) { doc in
                guard doc.pane(showing: local) == item.pane else { return false }
                return doc.removePane(item.pane) != .notFound
            }) ?? false
            if removed {
                pool.drop(item.address)
                changed = true
            }
        }

        // Live terminals labeled for a space, without a pane.
        let orphans = store.all.filter { m in
            guard m.isLive, let space = m.labels["herdr.space"], !space.isEmpty, !busy.contains(m.address) else { return false }
            let machine = m.machine ?? ""
            guard machineReady(machine), let doc = slots[machine]?.document else { return false }
            return doc.pane(showing: m.localID) == nil
        }.sorted { $0.address < $1.address }
        for m in orphans {
            let tab = m.labels["herdr.tab"].flatMap { $0.isEmpty ? nil : $0 }
            if await adopt(m.address, machine: m.machine ?? "", space: m.labels["herdr.space"] ?? "", tab: tab) { changed = true }
        }
        if changed { layoutChanged() }
    }

    /// Puts a live terminal where its labels say, without changing what is
    /// shown. A space or tab no layout has yet is made under the label's id.
    private func adopt(_ address: String, machine: String, space: String, tab: String?) async -> Bool {
        guard let c = connection, let slot = slots[machine] else { return false }
        busy.insert(address)
        defer { busy.remove(address) }
        do {
            // A listing taken just before it ended still shows it running, and
            // labels outlive the program: ask again.
            let r = try await c.call("terminal.get", ["terminal": .string(address)])
            let labels = r["labels"]?.stringMap ?? [:]
            let labeledTab = labels["herdr.tab"].flatMap { $0.isEmpty ? nil : $0 }
            guard r["state"]?.string == "live", labels["herdr.space"] == space, labeledTab == tab else { return false }
            if r["keep"]?.bool != true {
                _ = try await c.call("terminal.keep", ["terminal": .string(address), "keep": true])
            }
            let local = splitAddress(address).local
            let folder = r["foreground"]?["cwd"]?.string ?? r["cwd"]?.string ?? (machine.isEmpty ? NSHomeDirectory() : "")
            return try await slot.update(c) { doc in
                guard doc.pane(showing: local) == nil else { return false }
                let pane = LayoutDocument.pane(id: LayoutDocument.freshID("p"), terminal: local)
                let tabID = tab ?? LayoutDocument.freshID("tb")
                if doc.space(space) == nil {
                    doc.addSpace(LayoutDocument.space(id: space, name: "", folder: folder, tabs: [LayoutDocument.tab(id: tabID, name: "", pane: pane)]))
                    return true
                }
                if let existing = doc.spaces.flatMap(\.tabs).first(where: { $0.id == tabID }),
                   let last = existing.root.terminals.last?.pane ?? existing.root.blocks.last?.id
                {
                    return doc.split(last, axis: .row, newPane: pane, containerID: LayoutDocument.freshID("s"))
                }
                return doc.addTab(LayoutDocument.tab(id: tabID, name: "", pane: pane), toSpace: space)
            }
        } catch {
            return false
        }
    }
}
