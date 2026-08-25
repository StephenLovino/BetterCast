import Foundation

/// Client for `usbmuxd`, the daemon macOS already runs to talk to attached iOS
/// devices. Finder sync, Xcode and Sidecar all ride on it.
///
/// It multiplexes TCP connections over the cable and speaks a plist protocol on a
/// Unix socket:
///
///     [UInt32 LE total length][UInt32 LE version = 1][UInt32 LE type = 8 (plist)]
///     [UInt32 LE tag][XML plist payload]
///
/// Two requests matter: `ListDevices`, and `Connect(DeviceID, PortNumber)`. After a
/// successful Connect the same socket becomes a transparent byte pipe to that TCP
/// port on the device, which is exactly what `iproxy` provides as an external tool.
/// Speaking the protocol directly avoids shipping one.
enum Usbmux {
    static let socketPath = "/var/run/usbmuxd"

    struct Device: Hashable, Identifiable {
        /// usbmuxd's handle. Changes on every replug, so never persist it.
        let deviceID: Int
        /// Stable hardware identifier.
        let udid: String
        var id: String { udid }
    }

    enum Failure: Error, LocalizedError {
        case cannotReachDaemon
        case badResponse(String)
        case refused(Int)

        var errorDescription: String? {
            switch self {
            case .cannotReachDaemon: return "could not reach usbmuxd"
            case .badResponse(let why): return "unexpected usbmuxd response: \(why)"
            case .refused(let code):
                // 3 is what usbmuxd returns when the device is there but nothing is
                // listening on the port, which for us means the app is not open.
                return code == 3
                    ? "the device refused the connection — is BetterCast open on it?"
                    : "usbmuxd refused the connection (code \(code))"
            }
        }
    }

    // MARK: - Socket plumbing

    /// Open a connection to the daemon. The caller owns the returned descriptor.
    private static func openSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.cannotReachDaemon }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath.utf8CString
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw Failure.cannotReachDaemon
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            path.withUnsafeBytes { src in
                dest.copyMemory(from: src)
            }
        }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw Failure.cannotReachDaemon
        }
        return fd
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw Failure.badResponse("empty request") }
            while sent < data.count {
                let n = write(fd, base.advanced(by: sent), data.count - sent)
                guard n > 0 else { throw Failure.cannotReachDaemon }
                sent += n
            }
        }
    }

    private static func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: count)
        while out.count < count {
            let n = read(fd, &buffer, count - out.count)
            guard n > 0 else { throw Failure.cannotReachDaemon }
            out.append(contentsOf: buffer[0..<n])
        }
        return out
    }

    private static func le32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func readLE32(_ data: Data, at offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
    }

    /// Send one plist request and read the single plist reply.
    private static func exchange(_ fd: Int32, _ body: [String: Any], tag: UInt32) throws -> [String: Any] {
        var payload = body
        payload["ClientVersionString"] = "BetterCast"
        payload["ProgName"] = "BetterCast"
        payload["kLibUSBMuxVersion"] = 3

        let plist = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)

        var request = le32(UInt32(16 + plist.count))
        request.append(le32(1))   // protocol version
        request.append(le32(8))   // message type: plist
        request.append(le32(tag))
        request.append(plist)
        try writeAll(fd, request)

        let header = try readExactly(fd, 16)
        let total = Int(readLE32(header, at: 0))
        guard total >= 16 else { throw Failure.badResponse("short header") }
        let responseData = try readExactly(fd, total - 16)

        guard let reply = try PropertyListSerialization.propertyList(
            from: responseData, options: [], format: nil) as? [String: Any] else {
            throw Failure.badResponse("reply was not a dictionary")
        }
        return reply
    }

    // MARK: - Requests

    /// Every iOS device currently attached by cable.
    static func listDevices() throws -> [Device] {
        let fd = try openSocket()
        defer { close(fd) }

        let reply = try exchange(fd, ["MessageType": "ListDevices"], tag: 1)
        guard let list = reply["DeviceList"] as? [[String: Any]] else {
            throw Failure.badResponse("no DeviceList")
        }

        return list.compactMap { entry in
            guard let deviceID = entry["DeviceID"] as? Int,
                  let props = entry["Properties"] as? [String: Any],
                  let udid = props["SerialNumber"] as? String else { return nil }
            // Wi-Fi-paired devices show up here too; only the cable is of interest.
            if let kind = props["ConnectionType"] as? String, kind != "USB" { return nil }
            return Device(deviceID: deviceID, udid: udid)
        }
    }

    /// Open a pipe to `port` on the device. On success the returned descriptor carries
    /// raw bytes in both directions and the caller owns it.
    static func connect(deviceID: Int, port: UInt16) throws -> Int32 {
        let fd = try openSocket()

        // usbmuxd wants the port in network byte order inside the plist, which is the
        // one piece of this protocol that looks like a bug until you hit it.
        let swapped = Int(port.bigEndian)

        do {
            let reply = try exchange(fd, [
                "MessageType": "Connect",
                "DeviceID": deviceID,
                "PortNumber": swapped
            ], tag: 2)

            let code = (reply["Number"] as? Int) ?? -1
            guard code == 0 else {
                close(fd)
                throw Failure.refused(code)
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }
}
