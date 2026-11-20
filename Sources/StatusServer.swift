// Minimal HTTP server for /, /status and /ping on plain BSD sockets.
// Binds only to the given addresses (this Mac's Tailscale IPs).
// Not Network.framework: an NWListener bound to the Tailscale IP never completed the TCP handshake
// for connections from the same Mac.

import Darwin
import Foundation

final class StatusServer {
    struct Response {
        var code = "200 OK"
        var body: Data
    }

    let port: UInt16
    private let route: (String) -> Response?
    private var sources: [String: DispatchSourceRead] = [:]   // listen address -> accept source

    init(port: UInt16, route: @escaping (String) -> Response?) {
        self.port = port
        self.route = route
    }

    /// Listens on exactly these addresses; an empty list stops serving. Called on every discovery scan, so an
    /// address that failed to bind (e.g. port still held by a quitting copy) is retried a minute later.
    func bind(to addresses: [String]) {
        let wanted = Set(addresses)
        for (addr, src) in sources where !wanted.contains(addr) {
            src.cancel()
            sources[addr] = nil
        }
        let missing = wanted.subtracting(sources.keys)
        guard !missing.isEmpty else { return }
        for addr in missing.sorted() {
            guard let fd = listenSocket(addr) else {
                HeatLog.write("server: cannot listen on \(addr) port \(port) (errno \(errno))")
                continue
            }
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            src.setEventHandler { [weak self] in self?.accept(fd) }
            src.setCancelHandler { close(fd) }
            src.resume()
            sources[addr] = src
        }
        HeatLog.write("server: listening on \(sources.keys.sorted().joined(separator: ", ")) port \(port)")
    }

    private func listenSocket(_ addr: String) -> Int32? {
        let v6 = addr.contains(":")
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        if v6 { setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size)) }

        let ok: Bool
        if v6 {
            var sa = sockaddr_in6()
            sa.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            sa.sin6_family = sa_family_t(AF_INET6)
            sa.sin6_port = port.bigEndian
            guard inet_pton(AF_INET6, addr, &sa.sin6_addr) == 1 else { return fail(fd) }
            ok = withUnsafePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } } == 0
        } else {
            var sa = sockaddr_in()
            sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sa.sin_family = sa_family_t(AF_INET)
            sa.sin_port = port.bigEndian
            guard inet_pton(AF_INET, addr, &sa.sin_addr) == 1 else { return fail(fd) }
            ok = withUnsafePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
        }
        guard ok, listen(fd, 16) == 0 else { return fail(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    /// Closes fd but keeps errno from the call that failed, for the log.
    private func fail(_ fd: Int32) -> Int32? {
        let e = errno
        close(fd)
        errno = e
        return nil
    }

    private func accept(_ listenFD: Int32) {
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let fd = withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(listenFD, $0, &len) } }
        guard fd >= 0 else { return }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        _ = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard allowed(String(cString: host)) else { close(fd); return }

        // Accepted sockets inherit O_NONBLOCK from the listener; reads below must block (with a timeout).
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var nosig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))

        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { close(fd) }
            var req = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while req.count < 8192, req.range(of: Data("\r\n\r\n".utf8)) == nil {
                let n = read(fd, &buf, buf.count)
                guard n > 0 else { break }
                req.append(contentsOf: buf[0..<n])
            }
            guard !req.isEmpty, let self else { return }
            let line = String(decoding: req.prefix(1024), as: UTF8.self)
            let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let path = target.split(separator: "?").first.map(String.init) ?? "/"
            let r = DispatchQueue.main.sync { self.route(path) }
                ?? Response(code: "404 Not Found", body: Data("{\"error\":\"not found\"}".utf8))
            var out = Data("HTTP/1.1 \(r.code)\r\nContent-Type: application/json\r\nContent-Length: \(r.body.count)\r\nConnection: close\r\n\r\n".utf8)
            out.append(r.body)
            out.withUnsafeBytes { _ = write(fd, $0.baseAddress, out.count) }
        }
    }

    /// Answers only Tailscale addresses (100.64/10, fd7a:115c:a1e0::/48). macOS also delivers packets for the
    /// Tailscale IP that arrive on other interfaces, so the bind alone doesn't keep LAN hosts out.
    private func allowed(_ host: String) -> Bool {
        let h = host.split(separator: "%").first.map(String.init) ?? ""
        if h.lowercased().hasPrefix("fd7a:115c:a1e0:") { return true }
        let o = h.split(separator: ".").compactMap { Int($0) }
        return o.count == 4 && o[0] == 100 && (64...127).contains(o[1])
    }
}
