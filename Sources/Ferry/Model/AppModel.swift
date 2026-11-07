import AppKit
import Foundation
import Observation

enum Pane: Hashable { case mac, phone }

struct LocalItem: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let size: UInt64
    let modified: Date
    let isFolder: Bool

    var kind: String { FileKinds.kind(name: name, isFolder: isFolder) }
}

struct Crumb: Hashable {
    let id: UInt32
    let name: String
}

struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct NamePrompt: Identifiable, Equatable {
    enum Kind: Equatable {
        case newFolder(Pane)
        case renameRemote(UInt32)
        case renameLocal(URL)
    }
    let id = UUID()
    let kind: Kind
    let initial: String

    var title: String {
        if case .newFolder = kind { return "New Folder" }
        return "Rename"
    }
    var confirmLabel: String {
        if case .newFolder = kind { return "Create" }
        return "Rename"
    }
}

struct DeletePrompt: Identifiable {
    let id = UUID()
    let items: [RemoteItem]
    var title: String {
        items.count == 1 ? "Delete “\(items[0].name)” from your phone?"
                         : "Delete \(items.count) items from your phone?"
    }
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case waiting
        case connected
        case blocked(String)
    }

    // Connection
    var phase: Phase = .waiting
    var device: DeviceInfo?
    var storages: [StorageInfo] = []
    var storageID: UInt32?

    // Phone pane
    var crumbs: [Crumb] = []
    var remoteItems: [RemoteItem] = []
    var remoteSelection = Set<UInt32>()
    var remoteSort = [KeyPathComparator(\RemoteItem.name, comparator: .localizedStandard)]
    var remoteLoading = false

    // Mac pane
    var localFolder: URL = FileManager.default.homeDirectoryForCurrentUser
    var localItems: [LocalItem] = []
    var localSelection = Set<URL>()
    var localSort = [KeyPathComparator(\LocalItem.name, comparator: .localizedStandard)]

    // Shared
    var showHidden = false
    var jobs: [TransferJob] = []
    var alert: AlertInfo?
    var namePrompt: NamePrompt?
    var deletePrompt: DeletePrompt?

    @ObservationIgnored let session = MTPSession()
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var runnerTask: Task<Void, Never>?
    @ObservationIgnored private var listGeneration = 0

    // MARK: - Derived

    var currentStorage: StorageInfo? { storages.first { $0.id == storageID } }
    var currentFolderID: UInt32 { crumbs.last?.id ?? mtpRootFolder }
    var isTransferring: Bool { runnerTask != nil }
    var canUsePhone: Bool { phase == .connected && storageID != nil }
    var activeJob: TransferJob? { jobs.first { !$0.state.isFinished } }

    var sortedRemote: [RemoteItem] {
        let visible = showHidden ? remoteItems : remoteItems.filter { !$0.name.hasPrefix(".") }
        let sorted = visible.sorted(using: remoteSort)
        return sorted.filter(\.isFolder) + sorted.filter { !$0.isFolder }
    }

    var sortedLocal: [LocalItem] {
        let sorted = localItems.sorted(using: localSort)
        return sorted.filter(\.isFolder) + sorted.filter { !$0.isFolder }
    }

    var selectedRemoteItems: [RemoteItem] { remoteItems.filter { remoteSelection.contains($0.id) } }

    // MARK: - Lifecycle

    func start() {
        guard monitorTask == nil else { return }
        reloadLocal()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                let delay: Double = self.phase == .connected ? 4 : 1.5
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func shutdown() {
        monitorTask?.cancel()
        jobs.forEach { $0.cancel() }
        session.closeNow()
    }

    private func tick() async {
        if phase == .connected {
            // MTP is one-thing-at-a-time; don't poll in the middle of a transfer.
            guard !isTransferring, !remoteLoading else { return }
            do {
                let fresh = try await session.storages()
                if let info = try? await session.info() { device = info }
                await applyStorages(fresh)
            } catch {
                await disconnected()
            }
            return
        }

        switch await session.probe() {
        case .none:
            phase = .waiting
        case .blocked(let label):
            phase = .blocked(label)
        case .opened(let info):
            device = info
            phase = .connected
            crumbs = []
            do {
                await applyStorages(try await session.storages())
            } catch {
                await disconnected()
            }
        }
    }

    private func applyStorages(_ fresh: [StorageInfo]) async {
        let hadSelection = storageID.map { id in fresh.contains { $0.id == id } } ?? false
        storages = fresh
        if !hadSelection {
            storageID = fresh.first?.id
            crumbs = []
            remoteSelection = []
            await reloadRemote()
        }
    }

    private func disconnected() async {
        await session.close()
        device = nil
        storages = []
        storageID = nil
        crumbs = []
        remoteItems = []
        remoteSelection = []
        phase = .waiting
    }

    /// Quits other apps that commonly grab the phone's USB connection.
    func freeUpUSB() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Android File Transfer Agent", "Android File Transfer", "OpenMTP", "ptpcamerad"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        phase = .waiting
    }

    // MARK: - Phone navigation

    func selectStorage(_ id: UInt32) {
        guard id != storageID else { return }
        storageID = id
        crumbs = []
        remoteSelection = []
        Task { await reloadRemote() }
    }

    func openRemote(_ ids: Set<UInt32>) {
        let items = remoteItems.filter { ids.contains($0.id) }
        if items.count == 1, let folder = items.first, folder.isFolder {
            crumbs.append(Crumb(id: folder.id, name: folder.name))
            remoteSelection = []
            remoteItems = []
            Task { await reloadRemote() }
        } else if !items.isEmpty {
            download(items, to: localFolder)
        }
    }

    func goToCrumb(_ index: Int?) {
        if let index { crumbs = Array(crumbs.prefix(index + 1)) } else { crumbs = [] }
        remoteSelection = []
        Task { await reloadRemote() }
    }

    func remoteUp() {
        guard !crumbs.isEmpty else { return }
        goToCrumb(crumbs.count >= 2 ? crumbs.count - 2 : nil)
    }

    func reloadRemote() async {
        guard let storageID, phase == .connected else {
            remoteItems = []
            return
        }
        listGeneration += 1
        let generation = listGeneration
        let folder = currentFolderID
        remoteLoading = true
        defer { if generation == listGeneration { remoteLoading = false } }
        do {
            let items = try await session.list(storage: storageID, folder: folder)
            guard generation == listGeneration else { return }
            remoteItems = items
            let ids = Set(items.map(\.id))
            remoteSelection = remoteSelection.filter { ids.contains($0) }
        } catch {
            guard generation == listGeneration else { return }
            show(error, title: "Couldn't Open Folder")
        }
    }

    // MARK: - Mac navigation

    func reloadLocal() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: localFolder, includingPropertiesForKeys: keys, options: options)) ?? []
        localItems = urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return LocalItem(url: url,
                             name: url.lastPathComponent,
                             size: UInt64(values?.fileSize ?? 0),
                             modified: values?.contentModificationDate ?? .distantPast,
                             isFolder: values?.isDirectory ?? false)
        }
        let present = Set(localItems.map(\.url))
        localSelection = localSelection.filter { present.contains($0) }
    }

    func goLocal(_ url: URL) {
        localFolder = url
        localSelection = []
        reloadLocal()
    }

    func localUp() {
        let parent = localFolder.deletingLastPathComponent()
        if parent != localFolder { goLocal(parent) }
    }

    func openLocal(_ urls: Set<URL>) {
        let items = localItems.filter { urls.contains($0.url) }
        if items.count == 1, let folder = items.first, folder.isFolder {
            goLocal(folder.url)
        } else if !items.isEmpty {
            upload(items.map(\.url))
        }
    }

    func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = localFolder
        panel.prompt = "Show"
        if panel.runModal() == .OK, let url = panel.url { goLocal(url) }
    }

    func revealLocal(_ urls: Set<URL>) {
        NSWorkspace.shared.activateFileViewerSelecting(Array(urls))
    }

    func trashLocal(_ urls: Set<URL>) {
        for url in urls {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            catch { show(error, title: "Couldn't Move to Trash") }
        }
        reloadLocal()
    }

    // MARK: - Copying

    func copySelectionToMac() {
        download(selectedRemoteItems, to: localFolder)
    }

    func copySelectionToPhone() {
        upload(localItems.filter { localSelection.contains($0.url) }.map(\.url))
    }

    func remoteDragPayload(for item: RemoteItem) -> String {
        let ids = remoteSelection.contains(item.id) ? Array(remoteSelection) : [item.id]
        return "ferry-remote:" + ids.map(String.init).joined(separator: ",")
    }

    func handleRemoteDrop(_ strings: [String]) -> Bool {
        var ids = Set<UInt32>()
        for s in strings where s.hasPrefix("ferry-remote:") {
            s.dropFirst("ferry-remote:".count).split(separator: ",").compactMap { UInt32($0) }.forEach { ids.insert($0) }
        }
        let items = remoteItems.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return false }
        download(items, to: localFolder)
        return true
    }

    func handleFileDrop(_ urls: [URL]) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty, canUsePhone else { return false }
        upload(files)
        return true
    }

    func download(_ items: [RemoteItem], to destination: URL) {
        guard !items.isEmpty else { return }
        let title = items.count == 1 ? items[0].name : "\(items.count) items"
        let job = TransferJob(direction: .toMac, title: title) { [unowned self] job in
            let fm = FileManager.default
            var taken = Set((try? fm.contentsOfDirectory(atPath: destination.path(percentEncoded: false))) ?? [])
            var pending: [(RemoteItem, URL, Bool)] = items.map { ($0, destination, true) }
            var plan: [(RemoteItem, URL)] = []

            // Walk folders first so we know the total size up front.
            while !pending.isEmpty {
                if job.cancelFlag.isSet { throw CancellationError() }
                let (item, dir, topLevel) = pending.removeFirst()
                var name = Self.safeLocalName(item.name)
                if topLevel { name = Self.uniqueName(name, taken: &taken) }
                let target = dir.appending(path: name, directoryHint: item.isFolder ? .isDirectory : .notDirectory)
                if item.isFolder {
                    job.currentName = item.name
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    let children = try await self.session.list(storage: item.storageID, folder: item.id)
                    pending.append(contentsOf: children.map { ($0, target, false) })
                } else {
                    plan.append((item, target))
                    job.totalBytes += item.size
                    job.fileCount += 1
                }
            }

            job.state = .running
            for (item, target) in plan {
                if job.cancelFlag.isSet { throw CancellationError() }
                job.currentName = item.name
                let base = job.doneBytes
                let reporter = ProgressReporter(job: job)
                try await self.session.download(id: item.id, to: target.path(percentEncoded: false),
                                                progress: reporter.report)
                if item.modified.timeIntervalSince1970 > 0 {
                    try? fm.setAttributes([.modificationDate: item.modified],
                                          ofItemAtPath: target.path(percentEncoded: false))
                }
                job.updateProgress(base + item.size)
                job.filesDone += 1
            }
        }
        enqueue(job)
    }

    func upload(_ urls: [URL]) {
        guard let storageID, !urls.isEmpty else { return }
        let parent = currentFolderID
        let title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        let job = TransferJob(direction: .toPhone, title: title) { [unowned self] job in
            let fm = FileManager.default
            var taken = Set(try await self.session.list(storage: storageID, folder: parent).map(\.name))
            var pending: [(URL, UInt32, Bool)] = urls.map { ($0, parent, true) }
            var plan: [(URL, String, UInt32, UInt64)] = []

            while !pending.isEmpty {
                if job.cancelFlag.isSet { throw CancellationError() }
                let (url, remoteParent, topLevel) = pending.removeFirst()
                var name = url.lastPathComponent
                if name == ".DS_Store" { continue }
                if topLevel { name = Self.uniqueName(name, taken: &taken) }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    job.currentName = name
                    let folderID = try await self.session.createFolder(named: name, storage: storageID, parent: remoteParent)
                    let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                    pending.append(contentsOf: children.map { ($0, folderID, false) })
                } else {
                    let attributes = try? fm.attributesOfItem(atPath: url.path(percentEncoded: false))
                    let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
                    plan.append((url, name, remoteParent, size))
                    job.totalBytes += size
                    job.fileCount += 1
                }
            }

            job.state = .running
            for (url, name, remoteParent, size) in plan {
                if job.cancelFlag.isSet { throw CancellationError() }
                job.currentName = name
                let base = job.doneBytes
                let reporter = ProgressReporter(job: job)
                try await self.session.upload(from: url.path(percentEncoded: false), name: name, size: size,
                                              storage: storageID, parent: remoteParent,
                                              progress: reporter.report)
                job.updateProgress(base + size)
                job.filesDone += 1
            }
        }
        enqueue(job)
    }

    private func enqueue(_ job: TransferJob) {
        jobs.append(job)
        guard runnerTask == nil else { return }
        runnerTask = Task { [weak self] in
            guard let self else { return }
            while let job = self.jobs.first(where: { $0.state == .queued }) {
                job.state = .preparing
                do {
                    try await job.work(job)
                    job.state = job.cancelFlag.isSet ? .cancelled : .done
                } catch is CancellationError {
                    job.state = .cancelled
                } catch {
                    job.state = .failed(error.localizedDescription)
                }
                job.bytesPerSecond = 0
                if job.direction == .toPhone { await self.reloadRemote() } else { self.reloadLocal() }
            }
            self.runnerTask = nil
            if self.phase == .connected, let fresh = try? await self.session.storages() {
                self.storages = fresh
            }
        }
    }

    func clearFinishedJobs() {
        jobs.removeAll { $0.state.isFinished }
    }

    // MARK: - Folder / rename / delete

    func beginNewFolder(_ pane: Pane) {
        if pane == .phone, !canUsePhone { return }
        namePrompt = NamePrompt(kind: .newFolder(pane), initial: "untitled folder")
    }

    func beginRenameRemote() {
        guard let item = selectedRemoteItems.first, remoteSelection.count == 1 else { return }
        namePrompt = NamePrompt(kind: .renameRemote(item.id), initial: item.name)
    }

    func beginRenameLocal() {
        guard localSelection.count == 1, let url = localSelection.first else { return }
        namePrompt = NamePrompt(kind: .renameLocal(url), initial: url.lastPathComponent)
    }

    func commitNamePrompt(_ raw: String) {
        guard let prompt = namePrompt else { return }
        namePrompt = nil
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { return }

        switch prompt.kind {
        case .newFolder(.mac):
            do {
                try FileManager.default.createDirectory(at: localFolder.appending(path: name), withIntermediateDirectories: false)
                reloadLocal()
            } catch { show(error, title: "Couldn't Create Folder") }
        case .newFolder(.phone):
            guard let storageID else { return }
            let parent = currentFolderID
            Task {
                do {
                    let id = try await session.createFolder(named: name, storage: storageID, parent: parent)
                    await reloadRemote()
                    remoteSelection = [id]
                } catch { show(error, title: "Couldn't Create Folder") }
            }
        case .renameRemote(let id):
            Task {
                do {
                    try await session.rename(id: id, to: name)
                    await reloadRemote()
                } catch { show(error, title: "Couldn't Rename") }
            }
        case .renameLocal(let url):
            do {
                let target = url.deletingLastPathComponent().appending(path: name)
                try FileManager.default.moveItem(at: url, to: target)
                reloadLocal()
                localSelection = [target]
            } catch { show(error, title: "Couldn't Rename") }
        }
    }

    func beginDeleteRemote() {
        let items = selectedRemoteItems
        guard !items.isEmpty else { return }
        deletePrompt = DeletePrompt(items: items)
    }

    func confirmDelete(_ prompt: DeletePrompt) {
        deletePrompt = nil
        Task {
            for item in prompt.items {
                do { try await session.delete(id: item.id, name: item.name) }
                catch { show(error, title: "Couldn't Delete"); break }
            }
            remoteSelection = []
            await reloadRemote()
            if let fresh = try? await session.storages() { storages = fresh }
        }
    }

    func refreshAll() {
        reloadLocal()
        Task { await reloadRemote() }
    }

    func toggleHidden() {
        showHidden.toggle()
        reloadLocal()
    }

    // MARK: - Helpers

    func show(_ error: Error, title: String) {
        alert = AlertInfo(title: title, message: error.localizedDescription)
    }

    static func safeLocalName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    static func uniqueName(_ name: String, taken: inout Set<String>) -> String {
        var candidate = name
        if taken.contains(candidate) {
            let ns = name as NSString
            let ext = ns.pathExtension
            let base = ext.isEmpty ? name : ns.deletingPathExtension
            var n = 2
            repeat {
                candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                n += 1
            } while taken.contains(candidate)
        }
        taken.insert(candidate)
        return candidate
    }
}
