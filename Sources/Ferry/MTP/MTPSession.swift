import Foundation
import CLibMTP

/// Owns the single open MTP device. libmtp is not thread-safe and MTP itself
/// only does one operation at a time, so every call runs on one serial queue.
final class MTPSession: @unchecked Sendable {
    enum Probe {
        case none
        case opened(DeviceInfo)
        /// A device is plugged in but couldn't be opened (usually another app holds it,
        /// or the phone is locked / not in File Transfer mode).
        case blocked(String)
    }

    private let queue = DispatchQueue(label: "app.ferry.mtp", qos: .userInitiated)
    private var device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?

    private static let initialize: Void = { LIBMTP_Init() }()

    // MARK: - Plumbing

    private func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) }
            }
        }
    }

    private func requireDevice() throws -> UnsafeMutablePointer<LIBMTP_mtpdevice_t> {
        guard let device else { throw MTPError(message: "No phone is connected.") }
        return device
    }

    /// Reads and clears libmtp's error stack, building a readable error.
    private func failure(_ dev: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, _ summary: String) -> MTPError {
        var details: [String] = []
        var entry = LIBMTP_Get_Errorstack(dev)
        while let current = entry {
            if let text = current.pointee.error_text {
                details.append(String(cString: text))
            }
            entry = current.pointee.next
        }
        LIBMTP_Clear_Errorstack(dev)
        if let last = details.last, !last.isEmpty {
            return MTPError(message: "\(summary)\n\n\(last)")
        }
        return MTPError(message: summary)
    }

    private static func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    // MARK: - Connection

    func probe() async -> Probe {
        (try? await onQueue { self.probeOnQueue() }) ?? .none
    }

    private func probeOnQueue() -> Probe {
        _ = Self.initialize
        if let device { return .opened(Self.readInfo(device)) }

        var raw: UnsafeMutablePointer<LIBMTP_raw_device_t>? = nil
        var count: Int32 = 0
        let result = LIBMTP_Detect_Raw_Devices(&raw, &count)
        defer { if let raw { free(raw) } }
        guard result == LIBMTP_ERROR_NONE, let raw, count > 0 else { return .none }

        let entry = raw.pointee.device_entry
        var labelParts: [String] = []
        if let vendor = entry.vendor { labelParts.append(String(cString: vendor)) }
        if let product = entry.product { labelParts.append(String(cString: product)) }
        let label = labelParts.joined(separator: " ")

        guard let opened = LIBMTP_Open_Raw_Device_Uncached(raw) else {
            return .blocked(label.isEmpty ? "Your phone" : label)
        }
        device = opened
        return .opened(Self.readInfo(opened))
    }

    private static func readInfo(_ dev: UnsafeMutablePointer<LIBMTP_mtpdevice_t>) -> DeviceInfo {
        let friendly = takeString(LIBMTP_Get_Friendlyname(dev))
        let model = takeString(LIBMTP_Get_Modelname(dev))
        let maker = takeString(LIBMTP_Get_Manufacturername(dev))
        var maxLevel: UInt8 = 0
        var level: UInt8 = 0
        var battery: Double? = nil
        if LIBMTP_Get_Batterylevel(dev, &maxLevel, &level) == 0, maxLevel > 0 {
            battery = Double(level) / Double(maxLevel)
        }
        LIBMTP_Clear_Errorstack(dev)
        let name = !friendly.isEmpty ? friendly : (!model.isEmpty ? model : "Android phone")
        return DeviceInfo(name: name, manufacturer: maker, model: model, batteryLevel: battery)
    }

    func info() async throws -> DeviceInfo {
        try await onQueue { Self.readInfo(try self.requireDevice()) }
    }

    func close() async {
        _ = try? await onQueue { self.closeOnQueue() }
    }

    /// Synchronous release for app termination.
    func closeNow() {
        queue.sync { closeOnQueue() }
    }

    private func closeOnQueue() {
        if let device { LIBMTP_Release_Device(device) }
        device = nil
    }

    // MARK: - Browsing

    func storages() async throws -> [StorageInfo] {
        try await onQueue {
            let dev = try self.requireDevice()
            if LIBMTP_Get_Storage(dev, 0) < 0 {
                throw self.failure(dev, "Couldn't read the phone's storage.")
            }
            var result: [StorageInfo] = []
            var storage = dev.pointee.storage
            while let current = storage {
                let s = current.pointee
                var name = s.StorageDescription.map { String(cString: $0) } ?? ""
                if name.isEmpty { name = s.VolumeIdentifier.map { String(cString: $0) } ?? "" }
                let removable = s.StorageType == 2 || s.StorageType == 4
                if name.isEmpty { name = removable ? "SD Card" : "Internal Storage" }
                result.append(StorageInfo(id: s.id, name: name, capacity: s.MaxCapacity,
                                          free: s.FreeSpaceInBytes, isRemovable: removable))
                storage = s.next
            }
            LIBMTP_Clear_Errorstack(dev)
            return result
        }
    }

    func list(storage: UInt32, folder: UInt32) async throws -> [RemoteItem] {
        try await onQueue {
            let dev = try self.requireDevice()
            LIBMTP_Clear_Errorstack(dev)
            var file = LIBMTP_Get_Files_And_Folders(dev, storage, folder)
            if file == nil, LIBMTP_Get_Errorstack(dev) != nil {
                throw self.failure(dev, "Couldn't open this folder on the phone.")
            }
            var items: [RemoteItem] = []
            while let current = file {
                let f = current.pointee
                items.append(RemoteItem(
                    id: f.item_id,
                    parentID: f.parent_id,
                    storageID: f.storage_id,
                    name: f.filename.map { String(cString: $0) } ?? "Untitled",
                    size: f.filesize,
                    modified: Date(timeIntervalSince1970: TimeInterval(f.modificationdate)),
                    isFolder: f.filetype == LIBMTP_FILETYPE_FOLDER
                ))
                file = f.next
                LIBMTP_destroy_file_t(current)
            }
            return items
        }
    }

    // MARK: - Transfers

    func download(id: UInt32, to path: String,
                  progress: @escaping (UInt64, UInt64) -> Bool) async throws {
        try await onQueue {
            let dev = try self.requireDevice()
            let box = ProgressBox(progress)
            let context = Unmanaged.passRetained(box).toOpaque()
            defer { Unmanaged<ProgressBox>.fromOpaque(context).release() }
            LIBMTP_Clear_Errorstack(dev)
            if LIBMTP_Get_File_To_File(dev, id, path, progressThunk, context) != 0 {
                try? FileManager.default.removeItem(atPath: path)
                if box.cancelled {
                    LIBMTP_Clear_Errorstack(dev)
                    throw CancellationError()
                }
                throw self.failure(dev, "Couldn't copy “\((path as NSString).lastPathComponent)” from the phone.")
            }
        }
    }

    @discardableResult
    func upload(from path: String, name: String, size: UInt64, storage: UInt32, parent: UInt32,
                progress: @escaping (UInt64, UInt64) -> Bool) async throws -> UInt32 {
        try await onQueue {
            let dev = try self.requireDevice()
            guard let file = LIBMTP_new_file_t() else { throw MTPError(message: "Out of memory.") }
            defer { LIBMTP_destroy_file_t(file) } // also frees filename
            file.pointee.filename = strdup(name)
            file.pointee.filesize = size
            file.pointee.parent_id = parent
            file.pointee.storage_id = storage
            file.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN

            let box = ProgressBox(progress)
            let context = Unmanaged.passRetained(box).toOpaque()
            defer { Unmanaged<ProgressBox>.fromOpaque(context).release() }
            LIBMTP_Clear_Errorstack(dev)
            if LIBMTP_Send_File_From_File(dev, path, file, progressThunk, context) != 0 {
                if box.cancelled {
                    LIBMTP_Clear_Errorstack(dev)
                    throw CancellationError()
                }
                throw self.failure(dev, "Couldn't copy “\(name)” to the phone.")
            }
            return file.pointee.item_id
        }
    }

    // MARK: - File operations

    func createFolder(named name: String, storage: UInt32, parent: UInt32) async throws -> UInt32 {
        try await onQueue {
            let dev = try self.requireDevice()
            guard let cName = strdup(name) else { throw MTPError(message: "Out of memory.") }
            defer { free(cName) }
            LIBMTP_Clear_Errorstack(dev)
            let id = LIBMTP_Create_Folder(dev, cName, parent, storage)
            if id == 0 { throw self.failure(dev, "Couldn't create the folder “\(name)”.") }
            return id
        }
    }

    func delete(id: UInt32, name: String) async throws {
        try await onQueue {
            let dev = try self.requireDevice()
            LIBMTP_Clear_Errorstack(dev)
            if LIBMTP_Delete_Object(dev, id) != 0 {
                throw self.failure(dev, "Couldn't delete “\(name)”.")
            }
        }
    }

    func rename(id: UInt32, to name: String) async throws {
        try await onQueue {
            let dev = try self.requireDevice()
            LIBMTP_Clear_Errorstack(dev)
            if LIBMTP_Set_Object_String(dev, id, LIBMTP_PROPERTY_ObjectFileName, name) != 0 {
                throw self.failure(dev, "Couldn't rename to “\(name)”.")
            }
        }
    }
}

// MARK: - Progress bridging (C callback -> Swift closure)

private final class ProgressBox {
    let handler: (UInt64, UInt64) -> Bool
    var cancelled = false
    init(_ handler: @escaping (UInt64, UInt64) -> Bool) { self.handler = handler }
}

private let progressThunk: LIBMTP_progressfunc_t = { sent, total, context in
    guard let context else { return 0 }
    let box = Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue()
    if box.handler(sent, total) { return 0 }
    box.cancelled = true
    return 1
}
