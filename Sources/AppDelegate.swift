// Menu-bar app: samples this Mac, serves its status, discovers other HeatBars on the tailnet,
// heartbeats them, and shows every device in one menu.

import AppKit
import UserNotifications

enum Timing {
    static let sample: TimeInterval = 5          // local sample and heartbeat interval
    static let staleAfterMisses = 3
    static let offlineAfter: TimeInterval = 120
    static let offlinePoll: TimeInterval = 60
    static let hotFor: TimeInterval = 30
    static let alertCooldown: TimeInterval = 600
    static let discovery: TimeInterval = 60
    static let reprobe: TimeInterval = 600
    static let forgetAfter: TimeInterval = 24 * 3600
    static let periodicLog: TimeInterval = 300
}

enum HeatLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/HeatBar.log")

    static func write(_ s: String) {
        // Keep one previous log; start a new one past 1 MB.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
            let old = url.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

enum Presence: String { case online, stale, offline }

struct DeviceState {
    let id: String
    var name: String
    var ip: String?
    var dnsName: String?
    let isLocal: Bool
    var status: Status?
    var lastOK: Date?
    var misses = 0
    var history: [(Date, Double)] = []
    var hotSince: Date?
    var lastThermal = "nominal"
    var seenOnline = false
    var offlineAlerted = false
    var lastAlert: [String: Date] = [:]
    var lastSeenInTailnet = Date()
    var lastPoll = Date.distantPast
    var inFlight = false
    var lastPresence = Presence.online

    func presence(at now: Date) -> Presence {
        if isLocal { return .online }
        guard let lastOK, now.timeIntervalSince(lastOK) <= Timing.offlineAfter else { return .offline }
        return misses >= Timing.staleAfterMisses ? .stale : .online
    }

    mutating func record(_ t: Double, at now: Date) {
        history.append((now, t))
        history.removeAll { now.timeIntervalSince($0.0) > 3600 }
    }

    var peak: Double? {
        let own = history.map(\.1).max()
        guard let reported = status?.peak1h else { return own }
        return max(reported, own ?? reported)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let localID = "local"
    private let defaults = UserDefaults.standard
    private let started = Date()
    private var item: NSStatusItem!
    private var server: StatusServer!
    private let sensors = Sensors()
    private var devices: [String: DeviceState] = [:]
    private var probeAttempts: [String: Date] = [:]    // tailnet node ID -> last probe start
    private var tailscaleOK: Bool?
    private var latestTop: TopProcess?
    private var lastPeriodicLog = Date.distantPast
    private var timers: [Timer] = []

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.timeoutIntervalForResource = 4
        return URLSession(configuration: c)
    }()

    private var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
    private var threshold: Double {
        get { let v = defaults.double(forKey: "threshold"); return v == 0 ? 90 : v }
        set { defaults.set(newValue, forKey: "threshold") }
    }
    // Overridable for testing two instances on one Mac, e.g. -port 8766 -debugSelfAsPeer YES
    private var listenPort: UInt16 { UInt16(clamping: defaults.integer(forKey: "port") > 0 ? defaults.integer(forKey: "port") : 8765) }
    private var peerPort: Int { defaults.integer(forKey: "peerPort") > 0 ? defaults.integer(forKey: "peerPort") : 8765 }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ n: Notification) {
        defaults.removeObject(forKey: "remoteHost")   // v1.1 REMOTE mode setting, no longer used

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        setTitle("🖥 …", nil)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        devices[localID] = DeviceState(id: localID, name: Host.current().localizedName ?? "This Mac", isLocal: true)
        server = StatusServer(port: listenPort) { [weak self] path in self?.route(path) }
        HeatLog.write("HeatBar \(appVersion) started (threshold \(Int(threshold)) °C, port \(listenPort))")

        tick()
        rescan(force: true)
        timers = [
            Timer.scheduledTimer(withTimeInterval: Timing.sample, repeats: true) { [weak self] _ in self?.tick() },
            Timer.scheduledTimer(withTimeInterval: Timing.discovery, repeats: true) { [weak self] _ in self?.rescan(force: false) },
        ]
    }

    // MARK: local sampling and serving

    private func sampleLocal() {
        guard var d = devices[localID], let r = sensors?.read(), r.sensorCount > 0 else { return }
        let now = Date()
        d.record(r.chipMax, at: now)
        d.status = Status(host: d.name, appVersion: appVersion, time: now,
                          chipMax: r.chipMax, chipAvg: r.chipAvg, ssd: r.ssd,
                          thermalState: thermalName(ProcessInfo.processInfo.thermalState),
                          peak1h: d.history.map(\.1).max() ?? r.chipMax,
                          verdict: Verdict(temp: r.chipMax, threshold: threshold).rawValue,
                          top: latestTop)
        d.lastOK = now
        devices[localID] = d
        evaluateAlerts(localID)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let top = readTopProcess()
            DispatchQueue.main.async { self?.latestTop = top }
        }
    }

    private func route(_ path: String) -> StatusServer.Response? {
        let local = devices[localID]
        switch path {
        case "/", "/status":
            guard let s = local?.status else { return .init(code: "503 Service Unavailable", body: Data("{\"error\":\"no sensor data\"}".utf8)) }
            return .init(body: s.encoded())
        case "/ping":
            let d: [String: Any] = ["v": 2, "host": local?.name ?? "", "uptime": Int(Date().timeIntervalSince(started))]
            return .init(body: (try? JSONSerialization.data(withJSONObject: d)) ?? Data())
        default:
            return nil
        }
    }

    // MARK: discovery

    private func rescan(force: Bool) {
        PeerDiscovery.scan { [weak self] scan, note in
            guard let self else { return }
            guard let scan else {
                if self.tailscaleOK != false { HeatLog.write("discovery: \(note); serving on all interfaces") }
                self.tailscaleOK = false
                self.server.bind(to: nil)
                self.updateTitle()
                return
            }
            if self.tailscaleOK != true { HeatLog.write("discovery: tailscale ok, \(scan.macPeers.count) other Mac(s) on the tailnet") }
            self.tailscaleOK = true
            self.server.bind(to: scan.selfIPs.isEmpty ? nil : scan.selfIPs)
            self.devices[self.localID]?.ip = scan.selfIPs.first { $0.contains(".") }

            var peers = scan.macPeers
            if self.defaults.bool(forKey: "debugSelfAsPeer"), let ip = scan.selfIPs.first(where: { $0.contains(".") }) {
                peers.append(TailnetPeer(id: scan.selfID, name: "\(scan.selfName) (self test)", dnsName: nil, ip: ip))
            }

            let now = Date()
            for p in peers {
                if var d = self.devices[p.id] {
                    d.name = p.name
                    d.ip = p.ip
                    d.dnsName = p.dnsName
                    d.lastSeenInTailnet = now
                    self.devices[p.id] = d
                } else if force || now.timeIntervalSince(self.probeAttempts[p.id] ?? .distantPast) >= Timing.reprobe {
                    self.probe(p)
                }
            }
            for (id, d) in self.devices where !d.isLocal && now.timeIntervalSince(d.lastSeenInTailnet) > Timing.forgetAfter {
                HeatLog.write("discovery: forgetting \(d.name), not on the tailnet for 24 h")
                self.devices[id] = nil
            }
            self.updateTitle()
        }
    }

    private func probe(_ p: TailnetPeer) {
        probeAttempts[p.id] = Date()
        fetchStatus(p.ip, timeout: 2) { [weak self] s in
            guard let self, let s, self.devices[p.id] == nil else { return }
            let now = Date()
            var d = DeviceState(id: p.id, name: p.name, ip: p.ip, dnsName: p.dnsName, isLocal: false)
            d.status = s
            d.lastOK = now
            d.lastPoll = now
            d.seenOnline = true
            d.lastThermal = s.thermalState
            d.record(s.chipMax, at: now)
            self.devices[p.id] = d
            self.probeAttempts[p.id] = nil
            HeatLog.write("discovery: found HeatBar on \(p.name) (\(p.ip)), payload v\(s.version)")
            self.evaluateAlerts(p.id)
            self.updateTitle()
        }
    }

    private func fetchStatus(_ ip: String, timeout: TimeInterval, completion: @escaping (Status?) -> Void) {
        guard let url = URL(string: "http://\(ip):\(peerPort)/status") else { return completion(nil) }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        session.dataTask(with: req) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            let s = ok ? data.flatMap(Status.decode) : nil
            DispatchQueue.main.async { completion(s) }
        }.resume()
    }

    // MARK: heartbeat

    private func tick() {
        sampleLocal()
        let now = Date()
        for (id, d) in devices where !d.isLocal && !d.inFlight {
            let interval = d.presence(at: now) == .offline ? Timing.offlinePoll : Timing.sample
            guard let ip = d.ip, now.timeIntervalSince(d.lastPoll) >= interval - 0.5 else { continue }
            devices[id]?.inFlight = true
            devices[id]?.lastPoll = now
            fetchStatus(ip, timeout: 4) { [weak self] s in self?.heartbeat(id, s) }
        }
        for id in devices.keys { checkPresence(id) }

        if now.timeIntervalSince(lastPeriodicLog) >= Timing.periodicLog {
            lastPeriodicLog = now
            for d in devices.values {
                guard let s = d.status, d.presence(at: now) != .offline else { continue }
                HeatLog.write(String(format: "%@ chip max %.1f avg %.1f ssd %@ state %@", d.name, s.chipMax, s.chipAvg,
                                     s.ssd.map { String(format: "%.1f", $0) } ?? "-", s.thermalState))
            }
        }
        updateTitle()
    }

    private func heartbeat(_ id: String, _ s: Status?) {
        guard var d = devices[id] else { return }
        d.inFlight = false
        if let s {
            let wasOffline = d.offlineAlerted
            let now = Date()
            d.status = s
            d.lastOK = now
            d.misses = 0
            d.seenOnline = true
            d.offlineAlerted = false
            d.record(s.chipMax, at: now)
            devices[id] = d
            if wasOffline { alert(id, "online", "\(d.name) is back online", String(format: "Chip at %.0f °C.", s.chipMax), force: true) }
            evaluateAlerts(id)
        } else {
            d.misses += 1
            devices[id] = d
        }
        checkPresence(id)
        updateTitle()
    }

    private func checkPresence(_ id: String) {
        guard var d = devices[id], !d.isLocal else { return }
        let p = d.presence(at: Date())
        if p != d.lastPresence {
            HeatLog.write("\(d.name): \(d.lastPresence.rawValue) → \(p.rawValue)")
            d.lastPresence = p
            if p != .online { d.hotSince = nil }   // "hot for 30 s" must be 30 s of fresh readings
        }
        let sendOffline = p == .offline && d.seenOnline && !d.offlineAlerted
        if sendOffline { d.offlineAlerted = true }
        devices[id] = d
        if sendOffline {
            alert(id, "offline", "\(d.name) is unreachable",
                  "No answer for 2+ minutes. It may be off, asleep, crashed, or off Tailscale.", force: true)
        }
    }

    // MARK: alerts

    /// Called whenever a device has fresh data.
    private func evaluateAlerts(_ id: String) {
        guard var d = devices[id], let s = d.status else { return }
        let now = Date()
        if s.chipMax >= threshold { d.hotSince = d.hotSince ?? now } else { d.hotSince = nil }
        let hotLongEnough = d.hotSince.map { now.timeIntervalSince($0) >= Timing.hotFor } ?? false
        let throttleStarted = s.isThrottling && s.thermalState != d.lastThermal
        d.lastThermal = s.thermalState
        devices[id] = d

        let top = s.top.map { String(format: "\nTop: %@ (%.0f%% CPU)", $0.name, $0.cpu) } ?? ""
        if hotLongEnough {
            alert(id, "hot", String(format: "%@ is running hot: %.0f °C%@", d.name, s.chipMax, s.isThrottling ? " (throttling)" : ""),
                  String(format: "Above %.0f °C for 30+ s.", threshold) + top)
        }
        if throttleStarted {
            alert(id, "throttle", "\(d.name) is throttling for heat",
                  String(format: "macOS thermal state: %@, chip %.0f °C.", s.thermalState, s.chipMax) + top, force: true)
        }
    }

    private func alert(_ id: String, _ key: String, _ title: String, _ body: String, force: Bool = false) {
        guard var d = devices[id] else { return }
        let now = Date()
        if !force, let last = d.lastAlert[key], now.timeIntervalSince(last) < Timing.alertCooldown { return }
        d.lastAlert[key] = now
        devices[id] = d
        post(title, body)
    }

    private func post(_ title: String, _ body: String) {
        HeatLog.write("ALERT: \(title) — \(body.replacingOccurrences(of: "\n", with: " "))")
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { err in
            guard err != nil else { return }
            // Fallback when notification permission isn't granted
            let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "'") }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\" sound name \"Basso\""]
            try? p.run()
        }
    }

    // MARK: menu bar

    private func setTitle(_ s: String, _ color: NSColor?) {
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)]
        if let color { attrs[.foregroundColor] = color }
        item.button?.attributedTitle = NSAttributedString(string: s, attributes: attrs)
    }

    private func updateTitle() {
        let now = Date()
        let otherNotCool = devices.values.contains { d in
            guard !d.isLocal, d.presence(at: now) != .offline, let s = d.status else { return false }
            return Verdict(temp: s.chipMax, threshold: threshold) != .cool
        }
        let mark = otherNotCool ? " ⚠︎" : ""
        guard let t = devices[localID]?.status?.chipMax else { return setTitle("🖥 n/a" + mark, nil) }
        let color: NSColor? = t >= threshold ? .systemRed : (t >= threshold - 15 ? .systemOrange : nil)
        setTitle(String(format: "🖥 %.0f°", t) + mark, color)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()
        let sorted = devices.values.sorted {
            if $0.isLocal != $1.isLocal { return $0.isLocal }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let online = sorted.filter { $0.presence(at: now) == .online }.count
        menu.addItem(row("\(sorted.count) device\(sorted.count == 1 ? "" : "s") · \(online) online"))
        if tailscaleOK == false { menu.addItem(row("Tailscale not found")) }

        for d in sorted {
            menu.addItem(.separator())
            if sorted.count > 3 && !d.isLocal {
                let sub = NSMenu()
                sub.autoenablesItems = false
                addSection(d, to: sub, now: now)
                let summary: String
                if d.presence(at: now) == .offline { summary = "offline" }
                else if let s = d.status { summary = String(format: "%.0f° %@", s.chipMax, Verdict(temp: s.chipMax, threshold: threshold).emoji) }
                else { summary = "…" }
                let i = NSMenuItem(title: "\(d.name) — \(summary)", action: nil, keyEquivalent: "")
                i.submenu = sub
                menu.addItem(i)
            } else {
                addSection(d, to: menu, now: now)
            }
        }

        menu.addItem(.separator())
        let sub = NSMenu()
        for v in [80.0, 85, 90, 95, 100] {
            let i = NSMenuItem(title: "\(Int(v)) °C", action: #selector(setThreshold(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = v
            i.state = v == threshold ? .on : .off
            sub.addItem(i)
        }
        let th = NSMenuItem(title: "Alert above…", action: nil, keyEquivalent: "")
        th.submenu = sub
        menu.addItem(th)
        menu.addItem(action("Send test alert", #selector(testAlert)))
        menu.addItem(action("Open log", #selector(openLog)))
        menu.addItem(action("Rescan tailnet", #selector(rescanNow)))
        menu.addItem(action("About HeatBar \(appVersion)", #selector(about)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit HeatBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addSection(_ d: DeviceState, to menu: NSMenu, now: Date) {
        let p = d.presence(at: now)
        let dotColor: NSColor = p == .online ? .systemGreen : (p == .stale ? .systemOrange : .systemGray)
        let size = NSFont.menuFont(ofSize: 0).pointSize
        let header = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: dotColor, .font: NSFont.menuFont(ofSize: 0)])
        header.append(NSAttributedString(string: d.name + (d.ip.map { "  (\($0))" } ?? "") + (d.isLocal ? "  · this Mac" : ""),
                                         attributes: [.font: NSFont.boldSystemFont(ofSize: size)]))
        let h = NSMenuItem(title: d.name, action: nil, keyEquivalent: "")
        h.attributedTitle = header
        h.toolTip = d.dnsName
        menu.addItem(h)

        if p == .offline {
            menu.addItem(row("Offline — last seen \(ago(d.lastOK, now))", enabled: false))
            return
        }
        guard let s = d.status else { return menu.addItem(row("Waiting for sensor data…", enabled: false)) }
        let live = p == .online
        menu.addItem(row(String(format: "Chip (hottest):  %.1f °C", s.chipMax), enabled: live))
        menu.addItem(row(String(format: "Chip (average):  %.1f °C", s.chipAvg), enabled: live))
        if let ssd = s.ssd { menu.addItem(row(String(format: "SSD:  %.1f °C", ssd), enabled: live)) }
        menu.addItem(row("macOS thermal state:  \(s.thermalState)", enabled: live))
        if let peak = d.peak { menu.addItem(row(String(format: "Peak last hour:  %.1f °C", peak), enabled: live)) }
        menu.addItem(row("Verdict:  \(Verdict(temp: s.chipMax, threshold: threshold).label)", enabled: live))
        if let t = s.top { menu.addItem(row(String(format: "Top process:  %@ (%.0f%% CPU)", t.name, t.cpu), enabled: live)) }
        if p == .stale, let lastOK = d.lastOK {
            menu.addItem(row("No answer for \(Int(now.timeIntervalSince(lastOK))) s", enabled: false))
        }
    }

    private func row(_ title: String, enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = enabled
        return i
    }

    private func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    private func ago(_ date: Date?, _ now: Date) -> String {
        guard let date else { return "never" }
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "\(s) s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        return "\(s / 3600) h \(s % 3600 / 60) min ago"
    }

    @objc private func setThreshold(_ s: NSMenuItem) {
        threshold = s.representedObject as! Double
        for id in devices.keys { devices[id]?.hotSince = nil }
        updateTitle()
    }

    @objc private func testAlert() {
        let s = devices[localID]?.status
        post("HeatBar test", s.map { String(format: "Alerts work. This Mac's chip is at %.0f °C.", $0.chipMax) } ?? "Alerts work.")
    }

    @objc private func openLog() { NSWorkspace.shared.open(HeatLog.url) }

    @objc private func rescanNow() {
        probeAttempts.removeAll()
        rescan(force: true)
    }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "HeatBar",
            .applicationVersion: appVersion,
            .version: "",
            .credits: NSAttributedString(string: "Chip temperatures for every Mac on your tailnet."),
        ])
    }
}
