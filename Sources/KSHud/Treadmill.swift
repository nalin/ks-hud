import CoreBluetooth

/// Finds the first FTMS treadmill, subscribes to Treadmill Data, and reconnects when the link drops.
/// The only commands it sends are Start/Resume, Pause and Set Target Speed (plus Request Control, which FTMS requires first).
final class Treadmill: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum Link: Equatable {
        case searching
        case connecting(String)
        case connected(String)
        case unavailable(String)
    }

    private static let ftmsService = CBUUID(string: "1826")
    private static let treadmillData = CBUUID(string: "2ACD")
    private static let speedRangeChar = CBUUID(string: "2AD4")
    private static let controlPointChar = CBUUID(string: "2AD9")

    var onLink: ((Link) -> Void)?
    var onSample: ((TreadmillSample) -> Void)?
    /// nil when a command succeeded, otherwise why it failed.
    var onControlResult: ((String?) -> Void)?

    /// km/h limits reported by the treadmill (defaults match the KS-Z1D).
    private(set) var speedRange: ClosedRange<Double> = 1.6...6.4

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var controlPoint: CBCharacteristic?
    private var hasControl = false
    /// Control Point command waiting to be sent (or acknowledged).
    private var pendingCommand: Data?
    private var retriedControl = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func scan() {
        onLink?(.searching)
        central.scanForPeripherals(withServices: [Self.ftmsService])
    }

    var canControl: Bool { controlPoint != nil }

    func setTargetSpeed(_ kmh: Double) {
        let v = UInt16((min(max(kmh, speedRange.lowerBound), speedRange.upperBound) * 100).rounded())
        send(Data([0x02, UInt8(v & 0xFF), UInt8(v >> 8)]))
    }

    func start() {
        send(Data([0x07]))  // Start or Resume
    }

    /// Pause only; the app deliberately never sends Stop, so sessions are ended on the treadmill itself.
    func pause() {
        send(Data([0x08, 0x02]))  // Stop or Pause, parameter 0x02 = pause
    }

    private func send(_ command: Data) {
        guard let peripheral, let controlPoint else { return }
        pendingCommand = command
        retriedControl = false
        if hasControl {
            peripheral.writeValue(command, for: controlPoint, type: .withResponse)
        } else {
            requestControl()
        }
    }

    private func requestControl() {
        guard let peripheral, let controlPoint else { return }
        peripheral.writeValue(Data([0x00]), for: controlPoint, type: .withResponse)
    }

    /// Control Point indications are [0x80, request opcode, result code].
    private func handleControlResponse(_ bytes: [UInt8]) {
        guard bytes.count >= 3, bytes[0] == 0x80 else { return }
        let (opcode, result) = (bytes[1], bytes[2])
        switch (opcode, result) {
        case (0x00, 0x01):
            hasControl = true
            if let peripheral, let controlPoint, let pendingCommand {
                peripheral.writeValue(pendingCommand, for: controlPoint, type: .withResponse)
            }
        case (0x00, _):
            pendingCommand = nil
            onControlResult?("Treadmill refused remote control")
        case (_, 0x01):
            pendingCommand = nil
            onControlResult?(nil)
        case (_, 0x05) where !retriedControl:
            // Control was dropped (e.g. the phone app took it); ask again once.
            retriedControl = true
            hasControl = false
            requestControl()
        default:
            pendingCommand = nil
            let what = [0x07: "start", 0x08: "pause"][opcode] ?? "speed"
            onControlResult?(result == 0x02 ? "Remote \(what) not supported" : "Treadmill rejected \(what) (code \(result))")
        }
    }

    private func rescanSoon() {
        peripheral = nil
        controlPoint = nil
        hasControl = false
        pendingCommand = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.central.state == .poweredOn, self.peripheral == nil else { return }
            self.scan()
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: scan()
        case .poweredOff: onLink?(.unavailable("Bluetooth is off"))
        case .unauthorized: onLink?(.unavailable("Bluetooth permission denied"))
        case .unsupported: onLink?(.unavailable("Bluetooth LE unsupported"))
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        onLink?(.connecting(displayName(peripheral, advertisementData)))
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onLink?(.connected(displayName(peripheral)))
        peripheral.discoverServices([Self.ftmsService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        rescanSoon()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        rescanSoon()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == Self.ftmsService {
            peripheral.discoverCharacteristics([Self.treadmillData, Self.speedRangeChar, Self.controlPointChar], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] {
            switch ch.uuid {
            case Self.treadmillData:
                peripheral.setNotifyValue(true, for: ch)
            case Self.speedRangeChar:
                peripheral.readValue(for: ch)
            case Self.controlPointChar:
                controlPoint = ch
                peripheral.setNotifyValue(true, for: ch)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case Self.treadmillData:
            if let sample = FTMS.parseTreadmillData(data) { onSample?(sample) }
        case Self.speedRangeChar:
            // min, max, increment as uint16 in 0.01 km/h
            let b = [UInt8](data)
            guard b.count >= 4 else { return }
            let lo = Double(Int(b[0]) | Int(b[1]) << 8) / 100, hi = Double(Int(b[2]) | Int(b[3]) << 8) / 100
            if lo < hi { speedRange = lo...hi }
        case Self.controlPointChar:
            handleControlResponse([UInt8](data))
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.controlPointChar, let error else { return }
        pendingCommand = nil
        onControlResult?("Command failed: \(error.localizedDescription)")
    }

    private func displayName(_ p: CBPeripheral, _ adv: [String: Any] = [:]) -> String {
        adv[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? "Treadmill"
    }
}
