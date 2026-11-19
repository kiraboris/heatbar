// Reads Apple Silicon SoC temperatures through IOHIDEventSystemClient.
// The IOKit HID calls are private API, resolved at runtime with dlsym. No root needed.

import Foundation

private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Void
private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
private typealias CopyPropFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
private typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double

struct Reading {
    var chipMax: Double = 0
    var chipAvg: Double = 0
    var ssd: Double?
    var sensorCount = 0
}

final class Sensors {
    private let client: AnyObject
    private let copyServices: CopyServicesFn
    private let copyProp: CopyPropFn
    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn

    init?() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let c = dlsym(h, "IOHIDEventSystemClientCreate"),
              let m = dlsym(h, "IOHIDEventSystemClientSetMatching"),
              let s = dlsym(h, "IOHIDEventSystemClientCopyServices"),
              let p = dlsym(h, "IOHIDServiceClientCopyProperty"),
              let e = dlsym(h, "IOHIDServiceClientCopyEvent"),
              let f = dlsym(h, "IOHIDEventGetFloatValue")
        else { return nil }
        let create = unsafeBitCast(c, to: CreateFn.self)
        guard let cl = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        client = cl
        copyServices = unsafeBitCast(s, to: CopyServicesFn.self)
        copyProp = unsafeBitCast(p, to: CopyPropFn.self)
        copyEvent = unsafeBitCast(e, to: CopyEventFn.self)
        getFloat = unsafeBitCast(f, to: GetFloatFn.self)
        // PrimaryUsagePage 0xff00 / PrimaryUsage 5 = temperature sensors
        let match = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        unsafeBitCast(m, to: SetMatchingFn.self)(client, match)
    }

    func read() -> Reading {
        var r = Reading()
        guard let services = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return r }
        var chip: [Double] = []
        let kTemp: Int64 = 15
        for svc in services {
            let name = (copyProp(svc, "Product" as CFString)?.takeRetainedValue() as? String) ?? ""
            guard let ev = copyEvent(svc, kTemp, 0, 0)?.takeRetainedValue() else { continue }
            let t = getFloat(ev, Int32(kTemp << 16))
            guard t > 0, t < 150 else { continue }
            if name.contains("tdie") || name.contains("tdev") { chip.append(t) }   // SoC sensors ("tcal" is calibration, skipped)
            else if name.hasPrefix("NAND") { r.ssd = max(r.ssd ?? 0, t) }
        }
        if !chip.isEmpty {
            r.chipMax = chip.max()!
            r.chipAvg = chip.reduce(0, +) / Double(chip.count)
        }
        r.sensorCount = chip.count
        return r
    }
}
