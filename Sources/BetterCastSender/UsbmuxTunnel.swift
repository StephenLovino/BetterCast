import Foundation

/// Carries the stream to a cable-attached iOS device.
///
/// `usbmuxd` hands back a plain byte pipe, but everything above here speaks
/// `NWConnection`, so rather than teach the transport about file descriptors this
/// listens on a loopback port and pumps bytes between the two. The sender then dials
/// 127.0.0.1 and never learns it is talking over a cable, which is exactly how the
/// Android ADB path already works.
final class UsbmuxTunnel {
    private let deviceID: Int
    private let devicePort: UInt16
    let localPort: UInt16

    private var listenFD: Int32 = -1
    private var running = false
    private let queue = DispatchQueue(label: "com.bettercast.usbmux.tunnel")

    init(deviceID: Int, devicePort: UInt16 = BCConstants.tcpPort, localPort: UInt16 = BCConstants.usbForwardPort) {
        self.deviceID = deviceID
        self.devicePort = devicePort
        self.localPort = localPort
    }

    func start() throws {
        guard !running else { return }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Usbmux.Failure.cannotReachDaemon }

        // Without this a tunnel torn down a moment ago leaves the port in TIME_WAIT and
        // the next connect fails for a minute.
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = localPort.bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian  // loopback only, never the network

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw Usbmux.Failure.badResponse("could not listen on 127.0.0.1:\(localPort)")
        }

        listenFD = fd
        running = true
        LogManager.shared.log("USB: Tunnel ready on 127.0.0.1:\(localPort) → device port \(devicePort)")

        queue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        guard running else { return }
        running = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        LogManager.shared.log("USB: Tunnel closed")
    }

    private func acceptLoop() {
        while running {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else {
                if running { LogManager.shared.log("USB: Tunnel accept failed") }
                return
            }

            do {
                let device = try Usbmux.connect(deviceID: deviceID, port: devicePort)
                LogManager.shared.log("USB: Pipe open to device \(deviceID) port \(devicePort)")
                let session = PipeSession(a: client, b: device)
                pump(from: client, to: device, session: session)
                pump(from: device, to: client, session: session)
            } catch {
                LogManager.shared.log("USB: \(error.localizedDescription)")
                close(client)
            }
        }
    }

    /// Both descriptors of one tunnelled connection, closed exactly once.
    ///
    /// Each direction runs its own pump and either may finish first. Letting both close
    /// the pair would mean a second close on a number the kernel has already handed to
    /// something else, which is the kind of bug that corrupts an unrelated connection
    /// much later and looks like anything but a double close.
    private final class PipeSession {
        let a: Int32
        let b: Int32
        private var closed = false
        private let lock = NSLock()

        init(a: Int32, b: Int32) { self.a = a; self.b = b }

        func closeBoth() {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return }
            closed = true
            close(a)
            close(b)
        }
    }

    /// Shuttle bytes one way until either end goes quiet, then close the pair so the
    /// other direction's pump unblocks and exits too.
    private func pump(from source: Int32, to destination: Int32, session: PipeSession) {
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)

            // The base pointer is taken once and offset by hand. Writing
            // `&buffer[written]` instead looks equivalent and is not: that is an inout
            // access to a single element, so any write after a partial one sends bytes
            // from past a one-element temporary. Small messages survived it because
            // their first write covered everything; the first large keyframe did not,
            // and the receiver hung up on the garbage that followed.
            buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }

                while true {
                    let n = read(source, base, raw.count)
                    if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                    guard n > 0 else { break }

                    var written = 0
                    var failed = false
                    while written < n {
                        let w = write(destination, base.advanced(by: written), n - written)
                        if w < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                        guard w > 0 else { failed = true; break }
                        written += w
                    }
                    if failed { break }
                }
            }

            session.closeBoth()
        }
    }
}
