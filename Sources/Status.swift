// Status payload shared between HeatBar instances.
// v2 adds snake_case fields; the v1 camelCase fields are still sent so 1.1 viewers keep working.

import Foundation

enum Verdict: String {
    case cool, warm, gettingHot = "getting hot", hot

    init(temp t: Double, threshold: Double) {
        if t < 60 { self = .cool }
        else if t < threshold - 15 { self = .warm }
        else if t < threshold { self = .gettingHot }
        else { self = .hot }
    }

    var label: String {
        switch self {
        case .cool: "cool ✅"
        case .warm: "warm, normal under load"
        case .gettingHot: "getting hot ⚠️"
        case .hot: "HOT 🔥"
        }
    }

    var emoji: String {
        switch self { case .cool: "✅"; case .warm: "🟠"; case .gettingHot: "⚠️"; case .hot: "🔥" }
    }
}

struct TopProcess {
    var name: String
    var cpu: Double
}

struct Status {
    var version = 2
    var host: String?
    var appVersion: String?
    var time: Date?
    var chipMax: Double
    var chipAvg: Double
    var ssd: Double?
    var thermalState: String
    var peak1h: Double
    var verdict: String?
    var top: TopProcess?

    var isThrottling: Bool { thermalState == "serious" || thermalState == "critical" }

    private static func isoFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f
    }

    func encoded() -> Data {
        var d: [String: Any] = [
            "v": version,
            "chip_max": chipMax, "chip_avg": chipAvg,
            "thermal_state": thermalState, "peak_1h": peak1h,
            // v1 names
            "chipMax": chipMax, "chipAvg": chipAvg, "thermalState": thermalState, "peakHour": peak1h,
        ]
        if let host { d["host"] = host }
        if let appVersion { d["app_version"] = appVersion }
        if let time { d["time"] = Self.isoFormatter().string(from: time) }
        if let ssd { d["ssd"] = ssd }
        if let verdict { d["verdict"] = verdict }
        if let top {
            d["top_process"] = ["name": top.name, "cpu": top.cpu]
            d["topProcess"] = String(format: "%@ (%.1f%% CPU)", top.name, top.cpu)
        }
        return (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// Accepts v2 payloads and v1 payloads (no "v", camelCase keys, top process as a string).
    static func decode(_ data: Data) -> Status? {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func num(_ keys: String...) -> Double? {
            for k in keys { if let n = d[k] as? NSNumber { return n.doubleValue } }
            return nil
        }
        guard let chipMax = num("chip_max", "chipMax") else { return nil }
        var s = Status(
            version: (d["v"] as? NSNumber)?.intValue ?? 1,
            host: d["host"] as? String,
            appVersion: d["app_version"] as? String,
            time: (d["time"] as? String).flatMap { isoFormatter().date(from: $0) },
            chipMax: chipMax,
            chipAvg: num("chip_avg", "chipAvg") ?? chipMax,
            ssd: num("ssd"),
            thermalState: (d["thermal_state"] ?? d["thermalState"]) as? String ?? "unknown",
            peak1h: num("peak_1h", "peakHour") ?? chipMax,
            verdict: d["verdict"] as? String)
        if let t = d["top_process"] as? [String: Any], let name = t["name"] as? String {
            s.top = TopProcess(name: name, cpu: (t["cpu"] as? NSNumber)?.doubleValue ?? 0)
        } else if let t = d["topProcess"] as? String,
                  let m = t.range(of: #" \(([0-9.]+)% CPU\)$"#, options: .regularExpression) {
            let cpu = Double(t[m].filter { "0123456789.".contains($0) }) ?? 0
            s.top = TopProcess(name: String(t[..<m.lowerBound]), cpu: cpu)
        }
        return s
    }
}

func thermalName(_ s: ProcessInfo.ThermalState) -> String {
    switch s {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
}

/// Busiest process by CPU, via ps. Call off the main thread.
func readTopProcess() -> TopProcess? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-Aceo", "pcpu=,comm=", "-r"]
    let pipe = Pipe()
    p.standardOutput = pipe
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let line = String(data: data, encoding: .utf8)?.split(separator: "\n").first else { return nil }
    let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
    guard parts.count == 2, let cpu = Double(parts[0]) else { return nil }
    return TopProcess(name: String(parts[1]), cpu: cpu)
}
