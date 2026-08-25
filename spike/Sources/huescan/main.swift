import Foundation
import CoreBluetooth
import AppKit

// Spike: does this Mac see Philips Hue bulbs over BLE, and what do they expose?
//
// Hue BLE bulbs advertise service 0000fe0f (Philips Hue) and carry a proprietary
// light-control service 932c32bd-0000-47a2-835a-a8d455b859dd whose characteristics
// are the actual control surface. We scan broadly (nil filter) so we can also see
// bulbs that only advertise a name, then probe anything that looks like a Hue.
//
// Output goes to a log file, not stdout: TCC attributes a shell-exec'd binary to
// its parent process, so this has to be launched via `open` (LaunchServices) to be
// its own responsible process — and then stdout is detached.

enum HueUUID {
    // Declared in a nonisolated enum: top-level `let`s in main.swift are
    // MainActor-isolated under Swift 6, but CB delegate callbacks are not.
    nonisolated(unsafe) static let advertised = CBUUID(string: "FE0F")
    nonisolated(unsafe) static let control = CBUUID(string: "932c32bd-0000-47a2-835a-a8d455b859dd")
    nonisolated(unsafe) static let deviceInfo = CBUUID(string: "180A")
    nonisolated(unsafe) static let onOff = CBUUID(string: "932c32bd-0002-47a2-835a-a8d455b859dd")
}

nonisolated(unsafe) let logPath = ProcessInfo.processInfo.environment["HUESCAN_LOG"]
    ?? "\(NSHomeDirectory())/huescan.log"
nonisolated(unsafe) let logHandle: FileHandle? = {
    FileManager.default.createFile(atPath: logPath, contents: nil)
    return FileHandle(forWritingAtPath: logPath)
}()

func emit(_ s: String) {
    print(s)
    logHandle?.write((s + "\n").data(using: .utf8)!)
    try? logHandle?.synchronize()
}

final class Scanner: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var seen: [UUID: (name: String, rssi: Int, hueAdv: Bool)] = [:]
    var probing: [UUID: CBPeripheral] = [:]
    var connected = Set<UUID>()
    var bonded = Set<UUID>()
    var attempts = 0
    let deadline: Date
    /// In pair mode we write to the on/off characteristic instead of only reading.
    /// A write to an encrypted characteristic is the documented way to make
    /// CoreBluetooth initiate BLE bonding — there is no explicit pair() API.
    let pairMode: Bool

    init(seconds: Double, pairMode: Bool) {
        deadline = Date().addingTimeInterval(seconds)
        self.pairMode = pairMode
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            emit("[bt] powered on — scanning")
            // In pair mode we need duplicates: the bulb drops off the air when it is
            // power-cycled and we must notice it re-advertise to catch the pairing
            // window that opens shortly after power-on.
            c.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: pairMode
            ])
        case .unauthorized:
            emit("[bt] UNAUTHORIZED — Bluetooth permission denied for this app")
            finish(code: 2)
        case .poweredOff:
            emit("[bt] powered off")
            finish(code: 3)
        case .unsupported:
            emit("[bt] unsupported")
            finish(code: 4)
        default:
            emit("[bt] state=\(c.state.rawValue)")
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi RSSI: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "—"
        let services = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let isHueAdv = services.contains(HueUUID.advertised)
        // Hue bulbs typically name themselves "Hue Lamp", "Hue color lamp", "Hue ambiance…"
        let nameLooksHue = name.lowercased().contains("hue")

        if seen[p.identifier] == nil {
            seen[p.identifier] = (name, RSSI.intValue, isHueAdv)
            let mark = (isHueAdv || nameLooksHue) ? "  <<< HUE CANDIDATE" : ""
            let svc = services.isEmpty ? "" : "  svc=\(services.map { $0.uuidString }.joined(separator: ","))"
            let padded = name.padding(toLength: max(name.count, 26), withPad: " ", startingAt: 0)
            emit("  \(padded)  rssi=\(RSSI.intValue)\(svc)\(mark)")
        }

        if (isHueAdv || nameLooksHue), probing[p.identifier] == nil {
            probing[p.identifier] = p
            p.delegate = self
            emit("[probe] connecting to \(name)…")
            c.connect(p, options: nil)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        connected.insert(p.identifier)
        emit("[probe] CONNECTED \(p.name ?? "—") — discovering services")
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        emit("[probe] connect FAILED \(p.name ?? "—"): \(error?.localizedDescription ?? "?")")
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error { emit("[probe] service discovery error: \(e.localizedDescription)"); return }
        for s in p.services ?? [] {
            let known = s.uuid == HueUUID.control ? "  (HUE CONTROL SERVICE)" : ""
            emit("[probe]   service \(s.uuid.uuidString)\(known)")
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        if let e = error {
            emit("[probe]   char discovery error on \(s.uuid.uuidString): \(e.localizedDescription)")
            return
        }
        for ch in s.characteristics ?? [] {
            var props: [String] = []
            if ch.properties.contains(.read) { props.append("read") }
            if ch.properties.contains(.write) { props.append("write") }
            if ch.properties.contains(.writeWithoutResponse) { props.append("writeNR") }
            if ch.properties.contains(.notify) { props.append("notify") }
            emit("[probe]     char \(ch.uuid.uuidString) [\(props.joined(separator: ","))]")

            if pairMode {
                // Only poke the on/off characteristic, and only with a response —
                // writeWithoutResponse gives no error back, so it tells us nothing.
                if ch.uuid == HueUUID.onOff {
                    emit("[pair] >>> writing 0x01 (on) to on/off on \(p.name ?? "—") — expect a pairing prompt")
                    p.writeValue(Data([0x01]), for: ch, type: .withResponse)
                }
            } else if ch.properties.contains(.read) {
                p.readValue(for: ch)
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        attempts += 1
        if let e = error {
            emit("[pair] <<< attempt \(attempts) FAILED on \(p.name ?? "—"): \(e.localizedDescription)")
            // Drop the link so the next advertisement triggers a fresh connect. A
            // stale connection established before the power-cycle will never gain
            // encryption, so retrying on it is pointless.
            central.cancelPeripheralConnection(p)
        } else {
            emit("[pair] <<< attempt \(attempts) *** WRITE OK on \(p.name ?? "—") — BONDED ***")
            bonded.insert(p.identifier)
        }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        connected.remove(p.identifier)
        // Allow this peripheral to be picked up and retried on its next advertisement.
        probing[p.identifier] = nil
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if let e = error {
            emit("[probe]     read \(ch.uuid.uuidString) ERR: \(e.localizedDescription)")
            return
        }
        let d = ch.value ?? Data()
        let hex = d.map { String(format: "%02x", $0) }.joined(separator: " ")
        let printable = String(data: d, encoding: .utf8)?
            .filter { !$0.isNewline && ($0.isLetter || $0.isNumber || $0.isPunctuation || $0 == " ") } ?? ""
        emit("[probe]     read \(ch.uuid.uuidString) = [\(hex)]\(printable.isEmpty ? "" : " \"\(printable)\"")")
    }

    func summarise() {
        emit("")
        emit("=== summary ===")
        let candidates = seen.filter { $0.value.hueAdv || $0.value.name.lowercased().contains("hue") }
        emit("devices seen: \(seen.count)   hue candidates: \(candidates.count)   connected: \(connected.count)")
        if pairMode { emit("pair attempts: \(attempts)   BONDED: \(bonded.count)") }
        for (id, v) in candidates {
            emit("  \(v.name)  rssi=\(v.rssi)  hueAdvertised=\(v.hueAdv)  id=\(id)")
        }
        emit("=== done ===")
    }

    func finish(code: Int32) {
        summarise()
        exit(code)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let seconds = Double(args.first ?? "") ?? 20
let pairMode = args.contains("pair")

// Become a real foreground app. The system BLE pairing prompt is presented to the
// active application; as a background agent there may be nowhere to show it.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)

emit("[huescan] starting, \(Int(seconds))s, mode=\(pairMode ? "PAIR" : "scan"), log=\(logPath)")
let scanner = Scanner(seconds: seconds, pairMode: pairMode)

Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
    scanner.summarise()
    let found = scanner.seen.contains { $0.value.hueAdv || $0.value.name.lowercased().contains("hue") }
    exit(found ? 0 : 1)
}
app.run()
