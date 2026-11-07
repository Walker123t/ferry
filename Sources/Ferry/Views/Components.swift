import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Real Finder icons, looked up by file type and cached.
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(name: String, isFolder: Bool) -> NSImage {
        let key = isFolder ? "/folder" : (name as NSString).pathExtension.lowercased()
        if let cached = cache[key] { return cached }
        let type: UTType = isFolder ? .folder : (UTType(filenameExtension: key) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}

enum Format {
    static func bytes(_ value: UInt64) -> String {
        Int64(clamping: value).formatted(.byteCount(style: .file))
    }

    static func date(_ date: Date) -> String {
        // MTP folders often report 1970; treat anything before 1990 as unknown.
        guard date.timeIntervalSince1970 > 631_152_000 else { return "—" }
        if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(max(s, 1)) sec left" }
        if s < 3600 { return "\(s / 60) min left" }
        return "\(s / 3600) hr \((s % 3600) / 60) min left"
    }
}

struct FileNameCell: View {
    let name: String
    let isFolder: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: FileIcons.icon(name: name, isFolder: isFolder))
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Clickable path: root › folder › folder
struct Breadcrumbs: View {
    let root: String
    let rootIcon: String
    let parts: [String]
    let onSelect: (Int?) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    crumb(root, icon: rootIcon, isLast: parts.isEmpty) { onSelect(nil) }
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        Image(systemName: "chevron.compact.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        crumb(part, icon: nil, isLast: index == parts.count - 1) { onSelect(index) }
                            .id(index)
                    }
                }
                .padding(.horizontal, 10)
            }
            .onChange(of: parts.count) { _, count in
                withAnimation { proxy.scrollTo(count - 1, anchor: .trailing) }
            }
        }
        .frame(height: 28)
    }

    private func crumb(_ title: String, icon: String?, isLast: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 11)) }
                Text(title).lineLimit(1)
            }
            .font(.system(size: 12, weight: isLast ? .semibold : .regular))
            .foregroundStyle(isLast ? .primary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(CrumbButtonStyle())
    }
}

struct CrumbButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.06 : 0)))
            )
            .onHover { hovering = $0 }
    }
}

/// Header shared by both panes.
struct PaneHeader<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String?
    let tint: Color
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

struct DropHighlight: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.overlay {
            if active {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .background(Color.accentColor.opacity(0.06).clipShape(RoundedRectangle(cornerRadius: 10)))
                    .padding(4)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: active)
    }
}
