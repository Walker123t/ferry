import SwiftUI

struct MacPane: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    private var places: [(String, String, URL)] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return [
            ("Home", "house", home),
            ("Desktop", "menubar.dock.rectangle", home.appending(path: "Desktop")),
            ("Documents", "doc", home.appending(path: "Documents")),
            ("Downloads", "arrow.down.circle", home.appending(path: "Downloads")),
            ("Pictures", "photo", home.appending(path: "Pictures")),
            ("Movies", "film", home.appending(path: "Movies")),
            ("Music", "music.note", home.appending(path: "Music")),
        ]
    }

    private var pathParts: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.pathComponents
        let here = model.localFolder.standardizedFileURL.pathComponents
        if here.starts(with: home) { return Array(here.dropFirst(home.count)) }
        return Array(here.dropFirst()) // drop "/"
    }

    private var rootIsHome: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.pathComponents
        return model.localFolder.standardizedFileURL.pathComponents.starts(with: home)
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            PaneHeader(icon: "desktopcomputer", title: "This Mac",
                       subtitle: "\(model.localItems.count) items", tint: .indigo) {
                HStack(spacing: 4) {
                    Menu {
                        ForEach(places.indices, id: \.self) { index in
                            let place = places[index]
                            Button { model.goLocal(place.2) } label: { Label(place.0, systemImage: place.1) }
                        }
                        Divider()
                        Button("Choose Folder…") { model.chooseLocalFolder() }
                    } label: {
                        Label("Places", systemImage: "folder")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Go to a folder on your Mac")

                    IconButton("arrow.up", help: "Enclosing folder") { model.localUp() }
                    IconButton("folder.badge.plus", help: "New folder on Mac") { model.beginNewFolder(.mac) }
                }
            }

            Breadcrumbs(root: rootIsHome ? "Home" : "Mac",
                        rootIcon: rootIsHome ? "house" : "internaldrive",
                        parts: pathParts) { index in
                let base = rootIsHome ? FileManager.default.homeDirectoryForCurrentUser : URL(filePath: "/")
                guard let index else { model.goLocal(base); return }
                let url = pathParts.prefix(index + 1).reduce(base) { $0.appending(path: $1) }
                model.goLocal(url)
            }
            Divider()

            Table(of: LocalItem.self, selection: $model.localSelection, sortOrder: $model.localSort) {
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
                ForEach(model.sortedLocal) { item in
                    TableRow(item).draggable(item.url)
                }
            }
            .contextMenu(forSelectionType: URL.self) { urls in
                if !urls.isEmpty {
                    Button("Copy to Phone") { model.upload(Array(urls)) }
                        .disabled(!model.canUsePhone)
                    Divider()
                    Button("Show in Finder") { model.revealLocal(urls) }
                    Button("Rename…") { model.localSelection = urls; model.beginRenameLocal() }
                        .disabled(urls.count != 1)
                    Button("Move to Trash") { model.trashLocal(urls) }
                } else {
                    Button("New Folder") { model.beginNewFolder(.mac) }
                }
            } primaryAction: { urls in
                model.openLocal(urls)
            }
            .onDeleteCommand { model.trashLocal(model.localSelection) }
            .dropDestination(for: String.self) { strings, _ in
                model.handleRemoteDrop(strings)
            } isTargeted: { dropTargeted = $0 }
            .modifier(DropHighlight(active: dropTargeted))
            .overlay {
                if model.localItems.isEmpty {
                    ContentUnavailableView("Empty Folder", systemImage: "folder",
                                           description: Text("Drag files here from the phone."))
                }
            }
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(CrumbButtonStyle())
        .help(help)
    }
}
