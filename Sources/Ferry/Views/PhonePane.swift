import SwiftUI

struct PhonePane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.phase == .connected {
                PhoneBrowser()
            } else {
                ConnectView()
            }
        }
        .animation(.smooth(duration: 0.25), value: model.phase)
    }
}

private struct PhoneBrowser: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    private var subtitle: String {
        guard let storage = model.currentStorage else { return "Unlock your phone to see its files" }
        return "\(Format.bytes(storage.free)) free of \(Format.bytes(storage.capacity))"
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            PaneHeader(icon: "smartphone", title: model.device?.name ?? "Phone",
                       subtitle: subtitle, tint: .green) {
                HStack(spacing: 4) {
                    if model.storages.count > 1 {
                        Picker("Storage", selection: Binding(
                            get: { model.storageID ?? 0 },
                            set: { model.selectStorage($0) })) {
                            ForEach(model.storages) { storage in
                                Label(storage.name, systemImage: storage.isRemovable ? "sdcard" : "internaldrive")
                                    .tag(storage.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    IconButton("arrow.up", help: "Enclosing folder") { model.remoteUp() }
                        .disabled(model.crumbs.isEmpty)
                    IconButton("folder.badge.plus", help: "New folder on phone") { model.beginNewFolder(.phone) }
                    IconButton("arrow.clockwise", help: "Refresh") { Task { await model.reloadRemote() } }
                }
            }

            if let storage = model.currentStorage {
                StorageBar(storage: storage)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            Breadcrumbs(root: model.currentStorage?.name ?? "Phone",
                        rootIcon: model.currentStorage?.isRemovable == true ? "sdcard" : "internaldrive",
                        parts: model.crumbs.map(\.name)) { model.goToCrumb($0) }
            Divider()

            Table(of: RemoteItem.self, selection: $model.remoteSelection, sortOrder: $model.remoteSort) {
                TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                    FileNameCell(name: item.name, isFolder: item.isFolder)
                }
                .width(min: 130, ideal: 170)
                TableColumn("Size", value: \.size) { item in
                    Text(item.isFolder ? "—" : Format.bytes(item.size))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                .width(min: 54, ideal: 64, max: 90)
                TableColumn("Kind", value: \.kind, comparator: .localizedStandard) { item in
                    Text(item.kind).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 64, ideal: 96, max: 160)
                TableColumn("Modified", value: \.modified) { item in
                    Text(Format.date(item.modified)).foregroundStyle(.secondary)
                }
                .width(min: 84, ideal: 112, max: 170)
            } rows: {
                ForEach(model.sortedRemote) { item in
                    TableRow(item).draggable(model.remoteDragPayload(for: item))
                }
            }
            .contextMenu(forSelectionType: UInt32.self) { ids in
                if !ids.isEmpty {
                    Button("Copy to Mac") {
                        model.download(model.remoteItems.filter { ids.contains($0.id) }, to: model.localFolder)
                    }
                    Divider()
                    Button("Rename…") { model.remoteSelection = ids; model.beginRenameRemote() }
                        .disabled(ids.count != 1)
                    Button("Delete…", role: .destructive) { model.remoteSelection = ids; model.beginDeleteRemote() }
                } else {
                    Button("New Folder") { model.beginNewFolder(.phone) }
                    Button("Refresh") { Task { await model.reloadRemote() } }
                }
            } primaryAction: { ids in
                model.openRemote(ids)
            }
            .onDeleteCommand { model.beginDeleteRemote() }
            .dropDestination(for: URL.self) { urls, _ in
                model.handleFileDrop(urls)
            } isTargeted: { dropTargeted = $0 }
            .modifier(DropHighlight(active: dropTargeted))
            .overlay {
                if model.remoteLoading && model.remoteItems.isEmpty {
                    ProgressView().controlSize(.large)
                } else if model.remoteItems.isEmpty && model.storageID != nil {
                    ContentUnavailableView("Empty Folder", systemImage: "folder",
                                           description: Text("Drag files here from Finder or the Mac side."))
                } else if model.storageID == nil {
                    ContentUnavailableView("Phone Is Locked",
                                           systemImage: "lock.fill",
                                           description: Text("Unlock your phone and choose **File transfer** in the USB notification."))
                }
            }
        }
    }
}

private struct StorageBar: View {
    let storage: StorageInfo

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: storage.fractionUsed > 0.9 ? [.orange, .red] : [.green, .teal],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, geo.size.width * storage.fractionUsed))
            }
        }
        .frame(height: 5)
        .help("\(Format.bytes(storage.used)) used of \(Format.bytes(storage.capacity))")
    }
}
