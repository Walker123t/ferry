import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var nameText = ""

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HSplitView {
                MacPane()
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                PhonePane()
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
            TransferBar()
        }
        .animation(.smooth(duration: 0.25), value: model.jobs.count)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                DeviceBadge()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.copySelectionToMac()
                } label: {
                    Label("Copy to Mac", systemImage: "arrow.left.square")
                }
                .help("Copy the selected phone items into the folder open on the Mac side (⌥⌘←)")
                .disabled(model.remoteSelection.isEmpty || !model.canUsePhone)

                Button {
                    model.copySelectionToPhone()
                } label: {
                    Label("Copy to Phone", systemImage: "arrow.right.square")
                }
                .help("Copy the selected Mac items into the folder open on the phone side (⌥⌘→)")
                .disabled(model.localSelection.isEmpty || !model.canUsePhone)

                Button {
                    model.beginDeleteRemote()
                } label: {
                    Label("Delete from Phone", systemImage: "trash")
                }
                .help("Delete the selected items from the phone")
                .disabled(model.remoteSelection.isEmpty || !model.canUsePhone)
            }
        }
        .task { model.start() }
        .alert(model.namePrompt?.title ?? "",
               isPresented: Binding(get: { model.namePrompt != nil },
                                    set: { if !$0 { model.namePrompt = nil } })) {
            TextField("Name", text: $nameText)
            Button(model.namePrompt?.confirmLabel ?? "OK") { model.commitNamePrompt(nameText) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { model.namePrompt = nil }
        }
        .onChange(of: model.namePrompt) { _, prompt in
            nameText = prompt?.initial ?? ""
        }
        .confirmationDialog(model.deletePrompt?.title ?? "",
                            isPresented: Binding(get: { model.deletePrompt != nil },
                                                 set: { if !$0 { model.deletePrompt = nil } }),
                            presenting: model.deletePrompt) { prompt in
            Button("Delete", role: .destructive) { model.confirmDelete(prompt) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This can't be undone. Files deleted from the phone don't go to the Trash.")
        }
        .alert(model.alert?.title ?? "",
               isPresented: Binding(get: { model.alert != nil },
                                    set: { if !$0 { model.alert = nil } }),
               presenting: model.alert) { _ in
            Button("OK") {}
        } message: { info in
            Text(info.message)
        }
    }
}

/// Toolbar chip showing the connected phone and its battery.
private struct DeviceBadge: View {
    @Environment(AppModel.self) private var model

    private var batterySymbol: String {
        guard let level = model.device?.batteryLevel else { return "battery.100" }
        switch level {
        case 0.88...: return "battery.100"
        case 0.63...: return "battery.75"
        case 0.38...: return "battery.50"
        case 0.13...: return "battery.25"
        default: return "battery.0"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.phase == .connected ? Color.green : (model.phase == .waiting ? Color.secondary : Color.orange))
                .frame(width: 8, height: 8)
            switch model.phase {
            case .connected:
                Text(model.device?.name ?? "Phone").font(.system(size: 12, weight: .semibold))
                if let level = model.device?.batteryLevel {
                    HStack(spacing: 3) {
                        Image(systemName: batterySymbol)
                        Text(level, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            case .waiting:
                Text("No phone").font(.system(size: 12)).foregroundStyle(.secondary)
            case .blocked:
                Text("Phone busy").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }
}
