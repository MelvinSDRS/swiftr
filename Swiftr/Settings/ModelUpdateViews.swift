import SwiftUI

/// A download's bar, its bytes, and the button that stops it.
struct DownloadProgress: View {
    let done: Int64
    let total: Int64
    let stopHelp: String
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 2) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(width: 110)
                Text("\(ModelBytes.text(done)) of \(ModelBytes.text(total))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button(action: stop) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(stopHelp)
        }
    }
}

/// A downloaded model's buttons: Update when a newer version is out, and
/// Delete; the update's progress while it runs.
struct DownloadedActions: View {
    /// The model's key in `ModelUpdates`.
    let key: String
    /// Bytes it takes on this Mac.
    let used: Int64
    let update: () -> Void
    let stop: () -> Void
    let delete: () -> Void

    var body: some View {
        let updates = ModelUpdates.shared
        switch updates.steps[key] {
        case .downloading(let done, let total):
            DownloadProgress(done: done, total: total, stopHelp: "Stop Update", stop: stop)
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installing…").foregroundStyle(.secondary)
            }
            .help("Swiftr loads the new version once to see it works.")
        case nil:
            HStack(spacing: 10) {
                if updates.available[key] != nil {
                    Button("Update", action: update)
                        .buttonStyle(.borderedProminent)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(ModelBytes.text(used))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .help("Downloaded")
                }
                Button("Delete…", action: delete)
            }
        }
    }
}

/// Under a downloaded model: the newer version on offer, or why its
/// update failed.
struct ModelUpdateNote: View {
    let key: String

    var body: some View {
        let updates = ModelUpdates.shared
        if let failure = updates.failures[key] {
            Label(failure.said, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .help(failure.detail)
        } else if let update = updates.available[key], updates.steps[key] == nil {
            Label(offer(update), systemImage: "arrow.down.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func offer(_ update: ModelUpdate) -> String {
        let when = update.date.map { " on " + $0.formatted(.dateTime.month(.abbreviated).day().year()) } ?? ""
        let size = update.bytes > 0 ? " · \(ModelBytes.text(update.bytes))" : ""
        return "A newer version came out\(when)\(size)"
    }
}

/// When Swiftr last looked for newer models, and a button to look now.
struct ModelUpdatesRow: View {
    var body: some View {
        let updates = ModelUpdates.shared
        LabeledContent {
            HStack(spacing: 8) {
                if updates.checking {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Check Now") { updates.checkNow() }
                    .disabled(updates.checking)
            }
        } label: {
            Text("Last checked for updates")
            if let error = updates.checkError {
                Text("Swiftr couldn't check: \(error)")
                    .foregroundStyle(.red)
            } else if let at = updates.checkedAt {
                Text(at.formatted(date: Calendar.current.isDateInToday(at) ? .omitted : .abbreviated, time: .shortened))
            } else {
                Text("Not yet")
            }
        }
        .task { updates.checkIfStale() }
    }
}

enum ModelBytes {
    static func text(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
