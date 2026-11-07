import Foundation
import Observation

@MainActor
@Observable
final class TransferJob: Identifiable {
    enum Direction { case toPhone, toMac }
    enum State: Equatable {
        case queued, preparing, running, done, cancelled
        case failed(String)

        var isFinished: Bool {
            switch self {
            case .done, .cancelled, .failed: return true
            default: return false
            }
        }
    }

    let id = UUID()
    let direction: Direction
    let title: String
    var state: State = .queued
    var totalBytes: UInt64 = 0
    var doneBytes: UInt64 = 0
    var fileCount = 0
    var filesDone = 0
    var currentName = ""
    var bytesPerSecond: Double = 0
    /// Set the moment the user presses stop; the phone can take a while to wind down.
    var cancelRequested = false

    @ObservationIgnored let cancelFlag = CancelFlag()
    @ObservationIgnored let work: @MainActor (TransferJob) async throws -> Void
    @ObservationIgnored private var sampleTime: Date?
    @ObservationIgnored private var sampleBytes: UInt64 = 0
    @ObservationIgnored let startedAt = Date()

    init(direction: Direction, title: String, work: @escaping @MainActor (TransferJob) async throws -> Void) {
        self.direction = direction
        self.title = title
        self.work = work
    }

    var fraction: Double {
        if totalBytes == 0 { return state == .done ? 1 : 0 }
        return min(1, Double(doneBytes) / Double(totalBytes))
    }

    var secondsRemaining: Double? {
        guard bytesPerSecond > 1, totalBytes > doneBytes else { return nil }
        return Double(totalBytes - doneBytes) / bytesPerSecond
    }

    func cancel() {
        cancelRequested = true
        cancelFlag.set()
        if state == .queued { state = .cancelled }
    }

    func updateProgress(_ bytes: UInt64) {
        let now = Date()
        if let t = sampleTime {
            let dt = now.timeIntervalSince(t)
            if dt >= 0.5, bytes >= sampleBytes {
                let instant = Double(bytes - sampleBytes) / dt
                bytesPerSecond = bytesPerSecond == 0 ? instant : bytesPerSecond * 0.7 + instant * 0.3
                sampleTime = now
                sampleBytes = bytes
            }
        } else {
            sampleTime = now
            sampleBytes = bytes
        }
        doneBytes = bytes
    }
}

/// Receives per-file progress on the MTP thread and forwards a throttled
/// job-wide byte count to the main actor.
final class ProgressReporter: @unchecked Sendable {
    private let cancel: CancelFlag
    private let base: UInt64
    private let post: @Sendable (UInt64) -> Void
    private var lastPost: UInt64 = 0

    @MainActor
    init(job: TransferJob) {
        cancel = job.cancelFlag
        base = job.doneBytes
        post = { value in Task { @MainActor in job.updateProgress(value) } }
    }

    func report(sent: UInt64, total: UInt64) -> Bool {
        if cancel.isSet { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        if now &- lastPost > 120_000_000 || sent == total {
            lastPost = now
            post(base + sent)
        }
        return true
    }
}
