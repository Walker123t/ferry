import Foundation
import UniformTypeIdentifiers

/// The PTP/MTP handle that means "top level of a storage".
let mtpRootFolder: UInt32 = 0xFFFF_FFFF

struct DeviceInfo: Equatable {
    var name: String
    var manufacturer: String
    var model: String
    /// 0...1, nil when the phone doesn't report it.
    var batteryLevel: Double?
}

struct StorageInfo: Identifiable, Hashable {
    let id: UInt32
    let name: String
    let capacity: UInt64
    let free: UInt64
    let isRemovable: Bool

    var used: UInt64 { capacity >= free ? capacity - free : 0 }
    var fractionUsed: Double { capacity == 0 ? 0 : Double(used) / Double(capacity) }
}

struct RemoteItem: Identifiable, Hashable {
    let id: UInt32
    let parentID: UInt32
    let storageID: UInt32
    let name: String
    let size: UInt64
    let modified: Date
    let isFolder: Bool

    var kind: String { FileKinds.kind(name: name, isFolder: isFolder) }
}

struct MTPError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Thread-safe cancel switch shared between the UI and the MTP worker thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// "Folder", "MPEG-4 movie", "JPEG image"… the same names Finder uses.
enum FileKinds {
    private static let lock = NSLock()
    private static var cache: [String: String] = [:]

    static func kind(name: String, isFolder: Bool) -> String {
        if isFolder { return "Folder" }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext.isEmpty { return "Document" }
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[ext] { return cached }
        let description = UTType(filenameExtension: ext)?.localizedDescription
        let kind = (description?.isEmpty == false && !(description!.hasPrefix("dyn")))
            ? description!.prefix(1).uppercased() + description!.dropFirst()
            : "\(ext.uppercased()) file"
        cache[ext] = kind
        return kind
    }
}
