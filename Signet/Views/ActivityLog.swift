import SwiftUI
import UIKit

/// The steps of a running task (signing, installing). Shown as its latest step, with the full history on request,
/// instead of a list that grows down the screen.
struct ActivityLog: Equatable {
    enum Outcome: Equatable { case idle, running, succeeded, failed }

    struct Entry: Equatable, Identifiable {
        let id: Int
        let time: Date
        let text: String
    }

    private(set) var entries: [Entry] = []
    private(set) var outcome = Outcome.idle

    var isEmpty: Bool { entries.isEmpty }
    var latest: String? { entries.last?.text }

    /// Marks the task as running, clearing the previous run's history unless `keepingHistory`.
    mutating func start(keepingHistory: Bool = false) {
        if !keepingHistory { entries = [] }
        outcome = .running
    }

    mutating func append(_ text: String) {
        entries.append(Entry(id: entries.count, time: Date(), text: text))
    }

    mutating func finish(_ outcome: Outcome, _ text: String? = nil) {
        if let text { append(text) }
        self.outcome = outcome
    }

    /// The whole history with timestamps, for Copy.
    var text: String {
        entries.map { "\($0.time.formatted(.dateTime.hour().minute().second())) \($0.text)" }.joined(separator: "\n")
    }
}

/// One line: what's happening now (or how it ended), with an optional progress bar.
struct ActivityStatusRow: View {
    let log: ActivityLog
    var progress: Double?
    /// Shown instead of the latest step while running, e.g. a phase that changes more often than the log.
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                icon.frame(width: 20)
                let text = (log.outcome == .running ? detail : nil) ?? log.latest ?? ""
                Text(text)
                    .font(.subheadline)
                    .lineLimit(2)
                    .contentTransition(.opacity)
                    .animation(.default, value: text)
                Spacer(minLength: 0)
            }
            if let progress, log.outcome == .running {
                ProgressView(value: progress)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch log.outcome {
        case .idle: EmptyView()
        case .running: ProgressView()
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

/// The full history, collapsed by default and opened automatically when the task fails.
struct ActivityDetails: View {
    let log: ActivityLog
    /// Anything extra to include when copying, e.g. a library's own log.
    var extraCopyText: (() -> String)?
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(log.entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.time.formatted(.dateTime.hour().minute().second()))
                            .foregroundStyle(.secondary)
                        Text(entry.text)
                    }
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                }
            }
            Button {
                var text = log.text
                if let extra = extraCopyText?(), !extra.isEmpty { text += "\n\n" + extra }
                UIPasteboard.general.string = text
            } label: {
                Label("Copy Log", systemImage: "doc.on.doc")
            }
        } label: {
            Text("Details").badge(log.entries.count)
        }
        .onChange(of: log.outcome) { _, outcome in
            if outcome == .failed { expanded = true }
        }
    }
}
