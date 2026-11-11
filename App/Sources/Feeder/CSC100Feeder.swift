import CoreBluetooth
import Foundation
import os

/// Drives the TCG Archivist CSC100 feeder over Bluetooth LE.
///
/// The protocol was observed, not documented (see `docs/csc100-ble.md`): one
/// service with a command characteristic (write with response) and a status
/// characteristic (notify), plain ASCII both ways, no pairing. The feeder sends
/// `CONNECTED` on subscribe, answers `FWVER`, and answers `MOTOR:START:<len>`
/// with `MOTOR:CARDLEN_SET` then `MOTOR:COMPLETE` once a card has moved, or
/// `MOTOR:END` when the motor ran and no card came through (an empty hopper).
/// A feed that gets neither in time is reported as timed out.
///
/// CoreBluetooth calls back on the queue given to the central manager; this
/// driver passes the main queue, which is what makes its main-actor isolated
/// delegate conformances (SE-0470) honest and keeps all state on the actor the
/// views read from.
@Observable
final class CSC100Feeder: NSObject, FeederControlling {
    private(set) var state: FeederState = .idle

    private let logger = Logger(subsystem: "com.nsluke.RiftboundScanner", category: "feeder")
    private let clock = ContinuousClock()
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    /// Set while the user wants a link; cleared by `disconnect()` so a drop is
    /// not mistaken for a request to reconnect.
    private var wantsConnection = false
    /// Where status messages go while a feed is in flight.
    private var feedEvents: AsyncStream<Result<FeederMessage, FeederError>>.Continuation?

    private enum GATT {
        static let advertisedService = CBUUID(string: "1811")
        static let localName = "ESP_OTA_GATTS"
        static let service = CBUUID(string: "7E8A1E10-1234-4BCD-8AEF-1234567890AB")
        static let command = CBUUID(string: "7E8A1E11-1234-4BCD-8AEF-1234567890AB")
        static let status = CBUUID(string: "7E8A1E12-1234-4BCD-8AEF-1234567890AB")
    }

    override init() {
        super.init()
    }

    // MARK: - FeederControlling

    func connect() {
        wantsConnection = true
        if let central {
            startScanIfPoweredOn(central)
        } else {
            // Creating the manager triggers the Bluetooth permission prompt, so it
            // waits for the user's first request rather than app launch.
            state = .scanning
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    func feedOneCard(timeout: Duration) async throws {
        guard case .ready(let version) = state, peripheral != nil, commandCharacteristic != nil else {
            throw FeederError.notReady(state)
        }
        let (events, continuation) = AsyncStream<Result<FeederMessage, FeederError>>.makeStream(bufferingPolicy: .bufferingNewest(8))
        feedEvents = continuation
        state = .feeding
        defer {
            continuation.finish()
            feedEvents = nil
            if case .feeding = state {
                state = .ready(firmwareVersion: version)
            }
        }
        send(.feed(cardLength: FeederCommand.defaultCardLength))

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in events {
                    switch event {
                    case .success(.feedComplete): return
                    case .success(.feedEndedEmpty): throw FeederError.hopperEmpty
                    case .success: continue
                    case .failure(let error): throw error
                    }
                }
                throw CancellationError()
            }
            group.addTask { [clock] in
                try await clock.sleep(for: timeout)
                throw FeederError.timedOut
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    func stop() {
        guard peripheral?.state == .connected else { return }
        send(.stop)
    }

    func disconnect() {
        wantsConnection = false
        feedEvents?.yield(.failure(.disconnected))
        if let central {
            central.stopScan()
            if let peripheral {
                central.cancelPeripheralConnection(peripheral)
            }
        }
        forgetPeripheral()
        state = .idle
    }

    // MARK: - Link lifecycle

    private func startScanIfPoweredOn(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            guard peripheral == nil else { return }
            state = .scanning
            central.scanForPeripherals(withServices: [GATT.advertisedService])
        case .poweredOff:
            state = .failed(.bluetoothOff)
        case .unauthorized:
            state = .failed(.bluetoothUnauthorized)
        case .unsupported:
            state = .failed(.bluetoothUnsupported)
        case .resetting, .unknown:
            state = .scanning
        @unknown default:
            state = .scanning
        }
    }

    private func forgetPeripheral() {
        peripheral?.delegate = nil
        peripheral = nil
        commandCharacteristic = nil
        statusCharacteristic = nil
    }

    private func send(_ command: FeederCommand) {
        guard let peripheral, let commandCharacteristic else { return }
        logger.info("→ \(command.text, privacy: .public)")
        peripheral.writeValue(command.data, for: commandCharacteristic, type: .withResponse)
    }

    private func receive(_ message: FeederMessage) {
        logger.info("← \(String(describing: message), privacy: .public)")
        switch message {
        case .firmwareVersion(let version):
            switch state {
            case .ready: state = .ready(firmwareVersion: version)
            default: break
            }
        case .connected, .cardLengthSet, .feedComplete, .feedEndedEmpty, .unrecognized:
            break
        }
        feedEvents?.yield(.success(message))
    }

    private func linkDropped(_ failure: FeederFailure) {
        feedEvents?.yield(.failure(.disconnected))
        forgetPeripheral()
        guard wantsConnection, let central else {
            state = .idle
            return
        }
        state = .failed(failure)
        // The feeder advertises again once the link is gone; pick it back up.
        startScanIfPoweredOn(central)
    }
}

// MARK: - CBCentralManagerDelegate

extension CSC100Feeder: @MainActor CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard wantsConnection else { return }
        startScanIfPoweredOn(central)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        guard name == GATT.localName, self.peripheral == nil else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([GATT.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        linkDropped(.connectionFailed(error?.localizedDescription ?? String(localized: "Unknown error.")))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        linkDropped(.disconnected(error?.localizedDescription))
    }
}

// MARK: - CBPeripheralDelegate

extension CSC100Feeder: @MainActor CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == GATT.service }) else {
            failSetup(error, fallback: "The feeder service was not found.")
            return
        }
        peripheral.discoverCharacteristics([GATT.command, GATT.status], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        let characteristics = service.characteristics ?? []
        guard let command = characteristics.first(where: { $0.uuid == GATT.command }),
              let status = characteristics.first(where: { $0.uuid == GATT.status })
        else {
            failSetup(error, fallback: "The feeder characteristics were not found.")
            return
        }
        commandCharacteristic = command
        statusCharacteristic = status
        // Subscribe first: the feeder announces itself on subscribe, and
        // replies to everything over this characteristic.
        peripheral.setNotifyValue(true, for: status)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard characteristic.uuid == GATT.status else { return }
        if let error {
            failSetup(error, fallback: "Could not subscribe to the feeder.")
            return
        }
        state = .ready(firmwareVersion: nil)
        send(.firmwareVersion)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard characteristic.uuid == GATT.status, let value = characteristic.value else { return }
        receive(FeederMessage(parsing: value))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error {
            logger.error("write failed: \(error.localizedDescription, privacy: .public)")
            feedEvents?.yield(.failure(.writeFailed(error.localizedDescription)))
        }
    }

    private func failSetup(_ error: (any Error)?, fallback: String) {
        let detail = error?.localizedDescription ?? fallback
        if let central, let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        forgetPeripheral()
        state = .failed(.connectionFailed(detail))
    }
}
