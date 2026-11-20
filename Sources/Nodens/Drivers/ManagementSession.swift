import Foundation
import NodensCore

/// One TCP connection to an openvpn management port on 127.0.0.1, with a
/// reader thread that turns every line into a `ManagementEvent`.
final class ManagementSession: @unchecked Sendable {
    private let port: Int
    private let password: String
    private let onEvent: @Sendable (ManagementEvent) -> Void
    private let onClose: @Sendable () -> Void
    private let lock = NSLock()
    private var fd: Int32 = -1

    init(port: Int, password: String, onEvent: @escaping @Sendable (ManagementEvent) -> Void, onClose: @escaping @Sendable () -> Void) {
        self.port = port
        self.password = password
        self.onEvent = onEvent
        self.onClose = onClose
    }

    /// Connects and answers the password prompt. Blocking; call it off the main thread.
    func open() -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else {
            Darwin.close(socketFD)
            return false
        }
        var one: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        lock.lock()
        fd = socketFD
        lock.unlock()
        // The "ENTER PASSWORD:" prompt has no newline; the answer can go first.
        send(password)
        Thread.detachNewThread { [self] in readLoop(socketFD) }
        return true
    }

    func send(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        let bytes = Array((line + "\n").utf8)
        bytes.withUnsafeBufferPointer { buffer in
            _ = Darwin.write(fd, buffer.baseAddress, buffer.count)
        }
    }

    private func readLoop(_ socketFD: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var pending = [UInt8]()
        while true {
            let count = Darwin.read(socketFD, &buffer, buffer.count)
            if count <= 0 { break }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 10) {
                var line = Array(pending[..<newline])
                pending.removeSubrange(...newline)
                if line.last == 13 { line.removeLast() }
                onEvent(ManagementProtocol.parse(String(decoding: line, as: UTF8.self)))
            }
        }
        lock.lock()
        Darwin.close(socketFD)
        fd = -1
        lock.unlock()
        onClose()
    }
}
