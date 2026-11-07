// blescan — a throwaway CoreBluetooth probe for exploring the TCG Archivist CSC100.
//
// Compile:  swiftc -swift-version 5 -O Scripts/blescan.swift -o /tmp/blescan
// Scan:     /tmp/blescan scan [seconds]
// Dump:     /tmp/blescan dump <name-substring|uuid> [listen-seconds]
//           Connects, enumerates every service/characteristic/descriptor, reads what is
//           readable, subscribes to every notify/indicate characteristic and prints
//           incoming bytes as hex for `listen-seconds` (default 30).
// Write:    /tmp/blescan write <name-substring|uuid> <char-uuid> <hex-bytes> [listen-seconds]
//           Writes one value (with response when supported) and listens for replies.
// Shell:    /tmp/blescan shell <name-substring|uuid> <char-uuid>
//           Connects, subscribes to everything, then reads lines from stdin and writes
//           each one to <char-uuid>. A line is sent as UTF-8 text with \n, \r and \t
//           escapes honoured; a line starting with "hex " is sent as raw bytes.
//           Type "quit" to disconnect.
// Feed:     /tmp/blescan feed <name-substring|uuid> <speed> <seconds>
//           Connects, writes MOTOR:START:<speed>, listens for <seconds>, writes MOTOR:STOP,
//           listens 2 s more, disconnects. Always stops the motor, even on Ctrl-C.
// Fake:     /tmp/blescan fake
//           Advertises as ESP_OTA_GATTS with the CSC100's service so the vendor app
//           connects to the Mac instead of the feeder. Logs every write the app makes
//           and lets you type status strings to send back as notifications. Power the
//           real feeder OFF first so the app can only find the Mac.
//
// Deviation from the Swift 6.2 house style: this is a single-file script compiled in
// Swift 5 mode because CoreBluetooth delegate callbacks arrive on a private queue and a
// run-loop-driven CLI gains nothing from actor isolation. It is not shipped code.

import CoreBluetooth
import Foundation

func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined(separator: " ")
}

func printable(_ data: Data) -> String {
    let s = data.map { b -> Character in
        (0x20...0x7e).contains(b) ? Character(UnicodeScalar(b)) : "."
    }
    return String(s)
}

func parseHex(_ text: String) -> Data? {
    let cleaned = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ":", with: "")
    guard cleaned.count % 2 == 0 else { return nil }
    var out = Data()
    var index = cleaned.startIndex
    while index < cleaned.endIndex {
        let next = cleaned.index(index, offsetBy: 2)
        guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
        out.append(byte)
        index = next
    }
    return out
}

func describe(_ properties: CBCharacteristicProperties) -> String {
    var names: [String] = []
    if properties.contains(.read) { names.append("read") }
    if properties.contains(.write) { names.append("write") }
    if properties.contains(.writeWithoutResponse) { names.append("writeNoRsp") }
    if properties.contains(.notify) { names.append("notify") }
    if properties.contains(.indicate) { names.append("indicate") }
    if properties.contains(.broadcast) { names.append("broadcast") }
    if properties.contains(.authenticatedSignedWrites) { names.append("signedWrite") }
    if properties.contains(.extendedProperties) { names.append("ext") }
    return names.joined(separator: ",")
}

func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

enum Mode {
    case scan(seconds: Double)
    case dump(target: String, listen: Double)
    case write(target: String, characteristic: String, payload: Data, listen: Double)
    case shell(target: String, characteristic: String)
    case feed(target: String, speed: Int, seconds: Double)
}

let csc100CommandUUID = "7E8A1E11-1234-4BCD-8AEF-1234567890AB"

func unescape(_ text: String) -> Data {
    var out = ""
    var iterator = text.makeIterator()
    while let c = iterator.next() {
        if c == "\\", let n = iterator.next() {
            switch n {
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "0": out.append("\0")
            default: out.append(n)
            }
        } else {
            out.append(c)
        }
    }
    return Data(out.utf8)
}

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static var emergencyStop: (() -> Void)?
    let mode: Mode
    var central: CBCentralManager!
    var seen: [UUID: String] = [:]
    var target: CBPeripheral?
    var pendingServices = 0
    var characteristicsByUUID: [String: CBCharacteristic] = [:]

    init(mode: Mode) {
        self.mode = mode
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("[\(timestamp())] Bluetooth on, scanning…")
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            if case .scan(let seconds) = mode {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    central.stopScan()
                    print("\nScan finished: \(self.seen.count) peripheral(s).")
                    exit(0)
                }
            }
        case .unauthorized:
            print("Bluetooth access denied. Allow it in System Settings > Privacy & Security > Bluetooth for the app that launched this (Terminal or Claude).")
            exit(2)
        case .poweredOff:
            print("Bluetooth is off.")
            exit(2)
        default:
            print("Bluetooth state: \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "(no name)"
        if seen[peripheral.identifier] == nil {
            seen[peripheral.identifier] = name
            var line = "[\(timestamp())] \(name)  id=\(peripheral.identifier.uuidString)  rssi=\(RSSI)"
            if let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], !services.isEmpty {
                line += "  services=\(services.map(\.uuidString))"
            }
            if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
                line += "  mfg=[\(hex(mfg))]"
            }
            if let svcData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
                for (k, v) in svcData { line += "  svcdata[\(k.uuidString)]=[\(hex(v))]" }
            }
            if let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool {
                line += "  connectable=\(connectable)"
            }
            print(line)
        }

        guard target == nil else { return }
        let wanted: String
        switch mode {
        case .scan: return
        case .dump(let t, _), .write(let t, _, _, _), .shell(let t, _), .feed(let t, _, _): wanted = t
        }
        let matches = name.localizedCaseInsensitiveContains(wanted)
            || peripheral.identifier.uuidString.caseInsensitiveCompare(wanted) == .orderedSame
        guard matches else { return }
        print("[\(timestamp())] → connecting to \(name)")
        target = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[\(timestamp())] connected; MTU(withResponse)=\(peripheral.maximumWriteValueLength(for: .withResponse)) MTU(noResponse)=\(peripheral.maximumWriteValueLength(for: .withoutResponse))")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("[\(timestamp())] connect failed: \(error?.localizedDescription ?? "unknown")")
        exit(1)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[\(timestamp())] disconnected: \(error?.localizedDescription ?? "clean")")
        exit(0)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { print("service discovery failed: \(error)"); exit(1) }
        let services = peripheral.services ?? []
        print("\n\(services.count) service(s):")
        pendingServices = services.count
        for service in services {
            print("  service \(service.uuid.uuidString) \(service.uuid.description) primary=\(service.isPrimary)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { print("characteristic discovery failed for \(service.uuid): \(error)") }
        for c in service.characteristics ?? [] {
            print("    char \(c.uuid.uuidString) \(c.uuid.description) [\(describe(c.properties))]")
            characteristicsByUUID[c.uuid.uuidString.uppercased()] = c
            peripheral.discoverDescriptors(for: c)
            if c.properties.contains(.read) { peripheral.readValue(for: c) }
            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: c)
            }
        }
        pendingServices -= 1
        if pendingServices == 0 { afterDiscovery(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        for d in characteristic.descriptors ?? [] {
            print("      desc \(d.uuid.uuidString) \(d.uuid.description) (of \(characteristic.uuid.uuidString))")
            peripheral.readValue(for: d)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        if let error { print("      desc \(descriptor.uuid.uuidString) read error: \(error.localizedDescription)"); return }
        print("      desc \(descriptor.uuid.uuidString) = \(String(describing: descriptor.value ?? "nil"))")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            print("[\(timestamp())] \(characteristic.uuid.uuidString) read/notify error: \(error.localizedDescription)")
            return
        }
        let data = characteristic.value ?? Data()
        print("[\(timestamp())] \(characteristic.uuid.uuidString) ← (\(data.count)B) [\(hex(data))]  \"\(printable(data))\"")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            print("    notify \(characteristic.uuid.uuidString) failed: \(error.localizedDescription)")
        } else {
            print("    notify \(characteristic.uuid.uuidString) = \(characteristic.isNotifying)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            print("[\(timestamp())] write to \(characteristic.uuid.uuidString) failed: \(error.localizedDescription)")
        } else {
            print("[\(timestamp())] write to \(characteristic.uuid.uuidString) acknowledged")
        }
    }

    func afterDiscovery(_ peripheral: CBPeripheral) {
        let listen: Double
        switch mode {
        case .scan:
            return
        case .feed(_, let speed, let seconds):
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let c = self.characteristicsByUUID[csc100CommandUUID] else {
                    print("no command characteristic on this peripheral"); exit(1)
                }
                let start = Data("MOTOR:START:\(speed)".utf8)
                let stop = Data("MOTOR:STOP".utf8)
                let send: (Data) -> Void = { payload in
                    print("[\(timestamp())] → \"\(printable(payload))\"")
                    peripheral.writeValue(payload, for: c, type: .withResponse)
                }
                signal(SIGINT) { _ in
                    // Best effort: stop the motor before dying.
                    DispatchQueue.main.async {
                        print("\nCtrl-C: sending MOTOR:STOP")
                        Probe.emergencyStop?()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(130) }
                    }
                }
                Probe.emergencyStop = { send(stop) }
                send(start)
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    send(stop)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        print("\nDone; disconnecting.")
                        self.central.cancelPeripheralConnection(peripheral)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
                    }
                }
            }
            return
        case .shell(_, let charUUID):
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let c = self.characteristicsByUUID[charUUID.uppercased()] else {
                    print("no characteristic \(charUUID) on this peripheral; known: \(self.characteristicsByUUID.keys.sorted())")
                    exit(1)
                }
                let type: CBCharacteristicWriteType = c.properties.contains(.write) ? .withResponse : .withoutResponse
                print("\nShell ready. Type a command and press return (\\n escapes allowed, \"hex 01 02\" for raw bytes, \"quit\" to exit).")
                DispatchQueue.global().async {
                    while let line = readLine() {
                        if line == "quit" { DispatchQueue.main.async { self.central.cancelPeripheralConnection(peripheral) }; break }
                        if line.isEmpty { continue }
                        let payload: Data
                        if line.hasPrefix("hex ") {
                            guard let bytes = parseHex(String(line.dropFirst(4))) else { print("bad hex"); continue }
                            payload = bytes
                        } else {
                            payload = unescape(line)
                        }
                        DispatchQueue.main.async {
                            print("[\(timestamp())] → [\(hex(payload))] \"\(printable(payload))\"")
                            peripheral.writeValue(payload, for: c, type: type)
                        }
                    }
                }
            }
            return
        case .dump(_, let seconds):
            listen = seconds
            print("\nListening for notifications for \(Int(listen))s — poke the device/app now…")
        case .write(_, let charUUID, let payload, let seconds):
            listen = seconds
            // Wait a moment so descriptor/characteristic reads can land before we write.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let c = self.characteristicsByUUID[charUUID.uppercased()] else {
                    print("no characteristic \(charUUID) on this peripheral; known: \(self.characteristicsByUUID.keys.sorted())")
                    exit(1)
                }
                let type: CBCharacteristicWriteType = c.properties.contains(.write) ? .withResponse : .withoutResponse
                print("[\(timestamp())] → writing [\(hex(payload))] to \(c.uuid.uuidString) (\(type == .withResponse ? "withResponse" : "withoutResponse"))")
                peripheral.writeValue(payload, for: c, type: type)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + listen + 1.5) {
            print("\nDone listening; disconnecting.")
            self.central.cancelPeripheralConnection(peripheral)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
        }
    }
}

final class Impersonator: NSObject, CBPeripheralManagerDelegate {
    static let serviceUUID = CBUUID(string: "7E8A1E10-1234-4BCD-8AEF-1234567890AB")
    static let commandUUID = CBUUID(string: "7E8A1E11-1234-4BCD-8AEF-1234567890AB")
    static let statusUUID = CBUUID(string: "7E8A1E12-1234-4BCD-8AEF-1234567890AB")
    var manager: CBPeripheralManager!
    let status = CBMutableCharacteristic(type: Impersonator.statusUUID, properties: [.read, .notify], value: nil, permissions: [.readable])
    var lastStatus = Data("CONNECTED".utf8)

    override init() {
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            print("peripheral manager state: \(peripheral.state.rawValue)")
            if peripheral.state == .unauthorized { exit(2) }
            return
        }
        let command = CBMutableCharacteristic(type: Impersonator.commandUUID, properties: [.write], value: nil, permissions: [.writeable])
        let service = CBMutableService(type: Impersonator.serviceUUID, primary: true)
        service.characteristics = [command, status]
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { print("add service failed: \(error)"); exit(1) }
        // macOS ignores our local name in the advertisement and uses the Mac's own name,
        // so the app has to be finding the feeder by service UUID for this to work.
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: "ESP_OTA_GATTS",
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "1811"), Impersonator.serviceUUID],
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error { print("advertising failed: \(error)"); exit(1) }
        print("[\(timestamp())] advertising as ESP_OTA_GATTS. Open the vendor app now. Type a status string to notify it (e.g. CONNECTED), or quit.")
        DispatchQueue.global().async {
            while let line = readLine() {
                if line == "quit" { exit(0) }
                if line.isEmpty { continue }
                let payload = line.hasPrefix("hex ") ? (parseHex(String(line.dropFirst(4))) ?? Data()) : unescape(line)
                DispatchQueue.main.async {
                    self.lastStatus = payload
                    let ok = self.manager.updateValue(payload, for: self.status, onSubscribedCentrals: nil)
                    print("[\(timestamp())] status → [\(hex(payload))] \"\(printable(payload))\" sent=\(ok)")
                }
            }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        print("[\(timestamp())] central \(central.identifier) subscribed to \(characteristic.uuid.uuidString) (max update \(central.maximumUpdateValueLength)B)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            let ok = peripheral.updateValue(self.lastStatus, for: self.status, onSubscribedCentrals: [central])
            print("[\(timestamp())] status → \"\(printable(self.lastStatus))\" sent=\(ok)")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        print("[\(timestamp())] central \(central.identifier) unsubscribed from \(characteristic.uuid.uuidString)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        print("[\(timestamp())] READ \(request.characteristic.uuid.uuidString) offset=\(request.offset)")
        request.value = lastStatus
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            let data = request.value ?? Data()
            print("[\(timestamp())] WRITE \(request.characteristic.uuid.uuidString) (\(data.count)B) [\(hex(data))]  \"\(printable(data))\"")
            // Canned replies observed from the real feeder (firmware 0.1.5), so the app
            // gets past its handshake and shows us the commands that follow.
            if data == Data("FWVER".utf8) {
                let reply = Data("FWVER:0.1.5".utf8)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.lastStatus = reply
                    let ok = peripheral.updateValue(reply, for: self.status, onSubscribedCentrals: nil)
                    print("[\(timestamp())] status → \"FWVER:0.1.5\" (auto) sent=\(ok)")
                }
            }
        }
        if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
    }
}

let args = CommandLine.arguments.dropFirst()
if args.first == "fake" {
    let impersonator = Impersonator()
    _ = impersonator
    RunLoop.main.run()
}

let mode: Mode
switch args.first {
case "scan":
    mode = .scan(seconds: Double(args.dropFirst().first ?? "") ?? 10)
case "dump":
    guard let t = args.dropFirst().first else { print("usage: blescan dump <name|uuid> [listen-seconds]"); exit(64) }
    mode = .dump(target: t, listen: Double(args.dropFirst(2).first ?? "") ?? 30)
case "feed":
    let rest = Array(args.dropFirst())
    guard rest.count >= 3, let speed = Int(rest[1]), let seconds = Double(rest[2]) else {
        print("usage: blescan feed <name|uuid> <speed> <seconds>"); exit(64)
    }
    mode = .feed(target: rest[0], speed: speed, seconds: seconds)
case "shell":
    let rest = Array(args.dropFirst())
    guard rest.count >= 2 else { print("usage: blescan shell <name|uuid> <char-uuid>"); exit(64) }
    mode = .shell(target: rest[0], characteristic: rest[1])
case "write":
    let rest = Array(args.dropFirst())
    guard rest.count >= 3, let payload = parseHex(rest[2]) else {
        print("usage: blescan write <name|uuid> <char-uuid> <hex-bytes> [listen-seconds]"); exit(64)
    }
    mode = .write(target: rest[0], characteristic: rest[1], payload: payload, listen: Double(rest.count > 3 ? rest[3] : "") ?? 10)
default:
    print("usage: blescan scan [seconds] | dump <name|uuid> [listen-seconds] | write <name|uuid> <char-uuid> <hex> [listen-seconds] | shell <name|uuid> <char-uuid> | feed <name|uuid> <speed> <seconds> | fake")
    exit(64)
}

let probe = Probe(mode: mode)
RunLoop.main.run()
