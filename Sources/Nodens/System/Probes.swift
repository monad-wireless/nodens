import Foundation
import NodensCore

/// Lookups through the system resolver, the path every app uses.
enum DNSCheck {
    static func resolves(_ name: String) async -> Bool {
        let result = await Shell.run("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", name], timeout: 6)
        return result.succeeded && (result.stdout.contains("ip_address:") || result.stdout.contains("ipv6_address:"))
    }

    static func tailscaleHoldsDefault() async -> Bool? {
        let result = await Shell.run("/usr/sbin/scutil", ["--dns"], timeout: 5)
        guard result.succeeded else { return nil }
        return Scutil.tailscaleHoldsDefault(result.stdout)
    }
}

/// IPv4 addresses of a host name, through getaddrinfo off the main thread.
enum HostResolver {
    static func ipv4(_ host: String) async -> [String] {
        if ResolverPlan.isIPAddress(host) { return host.contains(":") ? [] : [host] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_STREAM
                var list: UnsafeMutablePointer<addrinfo>?
                var addresses: [String] = []
                if getaddrinfo(host, nil, &hints, &list) == 0 {
                    var cursor = list
                    while let info = cursor {
                        if info.pointee.ai_family == AF_INET, let address = info.pointee.ai_addr {
                            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                            address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                                var inAddr = pointer.pointee.sin_addr
                                _ = inet_ntop(AF_INET, &inAddr, &buffer, socklen_t(INET_ADDRSTRLEN))
                            }
                            let text = String(cString: buffer)
                            if !addresses.contains(text) { addresses.append(text) }
                        }
                        cursor = info.pointee.ai_next
                    }
                    freeaddrinfo(list)
                }
                continuation.resume(returning: addresses)
            }
        }
    }
}

/// Default locations of the VPN engines.
enum EngineLocator {
    static let homebrewOpenVPN = "/opt/homebrew/sbin/openvpn"
    static let tunnelblickBuilds = "/Applications/Tunnelblick.app/Contents/Resources/openvpn"
    static let homebrewWgQuick = "/opt/homebrew/bin/wg-quick"
    /// wg-quick needs bash 4 or later, and wireguard-go for the tunnel.
    static let homebrewBash = "/opt/homebrew/bin/bash"
    static let homebrewWireguardGo = "/opt/homebrew/bin/wireguard-go"

    /// Homebrew's openvpn when installed, else the newest build inside Tunnelblick.
    static func suggestedOpenVPN() -> String? {
        if FileManager.default.isExecutableFile(atPath: homebrewOpenVPN) { return homebrewOpenVPN }
        let builds = (try? FileManager.default.contentsOfDirectory(atPath: tunnelblickBuilds)) ?? []
        return builds
            .filter { $0.hasPrefix("openvpn-") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(tunnelblickBuilds)/\($0)/openvpn" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    static var wireGuardToolsReady: Bool {
        isExecutable(homebrewBash) && isExecutable(homebrewWireguardGo)
    }
}
