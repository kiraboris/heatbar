// Finds other Macs on the tailnet with `tailscale status --json`.
// Tailscale is used for discovery only. Whether a device is online comes from HeatBar's own heartbeats.

import Foundation

struct TailnetPeer {
    var id: String
    var name: String
    var dnsName: String?
    var ip: String
}

struct TailnetScan {
    var selfID: String
    var selfName: String
    var selfIPs: [String]
    var macPeers: [TailnetPeer]
}

enum PeerDiscovery {
    static let cliPaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    static func findCLI() -> String? {
        cliPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs the CLI off the main thread and calls back on main. A nil result means Tailscale is missing or not running.
    static func scan(completion: @escaping (TailnetScan?, String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let (scan, note) = runScan()
            DispatchQueue.main.async { completion(scan, note) }
        }
    }

    private static func runScan() -> (TailnetScan?, String) {
        guard let cli = findCLI() else { return (nil, "tailscale CLI not found") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["status", "--json"]
        // The Tailscale.app binary only acts as a CLI when SHLVL is set; launchd doesn't set it.
        var env = ProcessInfo.processInfo.environment
        env["SHLVL"] = env["SHLVL"] ?? "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (nil, "cannot run \(cli): \(error.localizedDescription)") }

        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let me = d["Self"] as? [String: Any], let myID = me["ID"] as? String
        else { return (nil, "tailscale status failed (exit \(p.terminationStatus))") }
        if let state = d["BackendState"] as? String, state != "Running" {
            return (nil, "tailscale backend is \(state)")
        }

        var peers: [TailnetPeer] = []
        for case let peer as [String: Any] in (d["Peer"] as? [String: Any] ?? [:]).values {
            guard peer["OS"] as? String == "macOS",
                  let id = peer["ID"] as? String,
                  let ip = (peer["TailscaleIPs"] as? [String])?.first(where: { $0.contains(".") })
            else { continue }
            peers.append(TailnetPeer(id: id, name: peer["HostName"] as? String ?? ip,
                                     dnsName: peer["DNSName"] as? String, ip: ip))
        }
        let scan = TailnetScan(selfID: myID, selfName: me["HostName"] as? String ?? "This Mac",
                               selfIPs: me["TailscaleIPs"] as? [String] ?? [], macPeers: peers)
        return (scan, "ok")
    }
}
