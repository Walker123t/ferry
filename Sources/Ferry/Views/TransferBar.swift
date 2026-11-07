import SwiftUI

/// Bottom strip showing the running transfer, with a popover listing all of them.
struct TransferBar: View {
    @Environment(AppModel.self) private var model
    @State private var showList = false

    private var focusJob: TransferJob? {
        model.activeJob ?? model.jobs.last
    }

    var body: some View {
        if let job = focusJob {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 12) {
                    JobSummary(job: job)
                    let waiting = model.jobs.filter { $0.state == .queued }.count
                    Button {
                        showList.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "list.bullet")
                            if waiting > 0 { Text("+\(waiting)").monospacedDigit() }
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("All transfers")
                    .popover(isPresented: $showList, arrowEdge: .top) {
                        TransferList().environment(model)
                    }
                    if job.state.isFinished {
                        Button { model.clearFinishedJobs() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help("Dismiss")
                    } else {
                        if job.cancelRequested {
                            ProgressView().controlSize(.small)
                        } else {
                            Button { job.cancel() } label: { Image(systemName: "stop.circle.fill").font(.title3) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Cancel this transfer")
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.bar)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct JobSummary: View {
    let job: TransferJob

    private var icon: String { job.direction == .toPhone ? "arrow.right.circle.fill" : "arrow.left.circle.fill" }

    private var detail: String {
        if job.cancelRequested && !job.state.isFinished {
            return "Cancelling… waiting for the phone to stop sending (can take up to a minute)"
        }
        switch job.state {
        case .queued: return "Waiting…"
        case .preparing: return "Getting ready… \(job.currentName)"
        case .running:
            var parts = ["\(Format.bytes(job.doneBytes)) of \(Format.bytes(job.totalBytes))"]
            if job.bytesPerSecond > 0 { parts.append("\(Format.bytes(UInt64(job.bytesPerSecond)))/s") }
            if let left = job.secondsRemaining { parts.append(Format.duration(left)) }
            if job.fileCount > 1 { parts.append("file \(min(job.filesDone + 1, job.fileCount)) of \(job.fileCount)") }
            return parts.joined(separator: " · ")
        case .done:
            let seconds = Date().timeIntervalSince(job.startedAt)
            return "Done · \(Format.bytes(job.totalBytes)) in \(Int(seconds.rounded()))s"
        case .cancelled: return "Cancelled"
        case .failed(let message): return message
        }
    }

    private var isFailed: Bool {
        if case .failed = job.state { return true }
        return false
    }

    private var tint: Color {
        switch job.state {
        case .failed: return .red
        case .cancelled: return .secondary
        case .done: return .green
        default: return .accentColor
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: job.state == .done ? "checkmark.circle.fill" : icon)
                .font(.system(size: 22))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(job.direction == .toPhone ? "To phone: \(job.title)" : "To Mac: \(job.title)")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    if job.state == .running {
                        Text(job.fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: job.fraction)
                    .progressViewStyle(.linear)
                    .tint(tint)
                    .opacity(job.state.isFinished ? 0.5 : 1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(isFailed ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .monospacedDigit()
            }
        }
    }
}

private struct TransferList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button("Clear Finished") { model.clearFinishedJobs() }
                    .disabled(!model.jobs.contains { $0.state.isFinished })
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.jobs.reversed()) { job in
                        HStack(alignment: .top) {
                            JobSummary(job: job)
                            if !job.state.isFinished {
                                Button { job.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 420, height: 320)
    }
}
