import CoreBluetooth
import Foundation
import Observation

struct FoundDevice: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var looksIFit: Bool { name.hasPrefix("I_TL") || name.hasPrefix("I_IT") || name.uppercased().contains("IFIT") }
}

@Observable
final class Treadmill: NSObject {
    enum Mode: String { case none = "—", ifit = "iFit", ftms = "FTMS" }

    var status = "Encendiendo Bluetooth…"
    var devices: [FoundDevice] = []
    var scanning = false
    var connectedName: String?
    var mode = Mode.none
    var ready = false
    var speed: Double?
    var incline: Double?
    var lastRX: Date?
    var log: [String] = []
    var targetSpeed: Double?
    var targetIncline: Double?
    /// Se llama cada vez que la cinta queda lista (también tras reconectar).
    var onReady: (() -> Void)?
    private var targetSpeedAt = Date.distantPast
    private var targetInclineAt = Date.distantPast

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var userDisconnected = false
    private var queue: [(Data, String?)] = []
    private var waitingWrite = false
    private var pollIndex = 0
    private var pendingSpeed: Double?
    private var pendingIncline: Double?
    private var pendingStart = false
    private var pendingStop = false
    private var cachedSpeedAfterStart: Double?
    private var pumpTimer: Timer?
    private var writeTimeout: DispatchWorkItem?
    private var lastRawRX: Data?
    private let logURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("cinta.log")
    private let savedKey = "treadmillPeripheral"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        addLog("--- arranque \(Date())")
    }

    // MARK: acciones

    func startScan() {
        guard central.state == .poweredOn else { return }
        devices.removeAll()
        scanning = true
        status = "Buscando…"
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central.stopScan()
        scanning = false
    }

    func connect(_ p: CBPeripheral) {
        stopScan()
        userDisconnected = false
        peripheral = p
        p.delegate = self
        UserDefaults.standard.set(p.identifier.uuidString, forKey: savedKey)
        status = "Conectando a \(p.name ?? "?")…"
        addLog("conectar \(p.name ?? "?") \(p.identifier)")
        central.connect(p)
    }

    func disconnect() {
        userDisconnected = true
        UserDefaults.standard.removeObject(forKey: savedKey)
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    func setSpeed(_ kmh: Double) {
        let v = min(16, max(0, (kmh * 10).rounded() / 10))
        targetSpeed = v; targetSpeedAt = Date()
        addLog("» velocidad \(v)")
        if mode == .ftms {
            if (speed ?? 0) == 0 && v > 0 { ftmsWrite(FTMS.start, "start") }
            ftmsWrite(FTMS.speed(v), "velocidad \(v)")
            return
        }
        if v > 0 && (speed ?? 0) == 0 {
            cachedSpeedAfterStart = v
            pendingStart = true
            addLog("parada: primero start, luego \(v)")
        } else {
            pendingSpeed = v
        }
    }

    func setIncline(_ pct: Double) {
        let v = min(10, max(0, (pct * 10).rounded() / 10))
        targetIncline = v; targetInclineAt = Date()
        addLog("» inclinación \(v)")
        if mode == .ftms { ftmsWrite(FTMS.incline(v), "inclinación \(v)"); return }
        pendingIncline = v
    }

    func start() {
        addLog("» start")
        if mode == .ftms { ftmsWrite(FTMS.start, "start"); return }
        pendingStart = true
    }

    func stop() {
        addLog("» stop")
        targetSpeed = 0; targetSpeedAt = Date()
        cachedSpeedAfterStart = nil
        if mode == .ftms { ftmsWrite(FTMS.stop, "stop"); return }
        pendingStop = true
    }

    /// Base para los saltos ±: el objetivo recién mandado o, si ya pasó, la velocidad real.
    var speedBase: Double {
        if let t = targetSpeed, Date().timeIntervalSince(targetSpeedAt) < 5 { return t }
        return speed ?? 0
    }
    var inclineBase: Double {
        if let t = targetIncline, Date().timeIntervalSince(targetInclineAt) < 8 { return t }
        return incline ?? 0
    }

    var logFileURL: URL { logURL }

    // MARK: cola de escritura

    private func enqueue(_ frames: [Data], _ label: String?) {
        for (i, f) in frames.enumerated() { queue.append((f, i == 0 ? label : nil)) }
        pump()
    }

    private func pump() {
        guard !waitingWrite, let p = peripheral, let c = writeChar, !queue.isEmpty else { return }
        let (data, label) = queue.removeFirst()
        let withResponse = c.properties.contains(.write)
        if let label { addLog(">> \(data.hex)  // \(label)") }
        waitingWrite = true
        p.writeValue(data, for: c, type: withResponse ? .withResponse : .withoutResponse)
        let work = DispatchWorkItem { [weak self] in self?.writeDone() }
        writeTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (withResponse ? 0.3 : 0.05), execute: work)
    }

    private func writeDone() {
        writeTimeout?.cancel()
        writeTimeout = nil
        waitingWrite = false
        pump()
    }

    private func runInit() {
        addLog("init iFit (\(IFit.initFrames.count) tramas)")
        status = "Inicializando…"
        // QZ espera 400 ms entre tramas de inicio.
        for (i, f) in IFit.initFrames.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 * Double(i)) { [weak self] in
                guard let self, self.peripheral?.state == .connected else { return }
                self.enqueue([f], i == 0 ? "init" : nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 * Double(IFit.initFrames.count) + 0.3) { [weak self] in
            guard let self, self.peripheral?.state == .connected else { return }
            self.ready = true
            self.status = "Lista"
            self.addLog("init hecho; sondeo cada 200 ms")
            self.startPolling()
            self.onReady?()
        }
    }

    private func startPolling() {
        pumpTimer?.invalidate()
        pollIndex = 0
        pumpTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.pollTick() }
    }

    private func pollTick() {
        guard ready, queue.isEmpty, !waitingWrite else { return }
        let i = pollIndex
        pollIndex = (pollIndex + 1) % IFit.pollFrames.count
        enqueue([IFit.pollFrames[i]], nil)
        if i == 2 {
            if let v = pendingIncline { enqueue(IFit.inclineFrames(v), "inclinación \(v)"); pendingIncline = nil }
            if let v = pendingSpeed { enqueue(IFit.speedFrames(v), "velocidad \(v)"); pendingSpeed = nil }
        }
        if i == 5 {
            if pendingStart { enqueue(IFit.startFrames, "start"); pendingStart = false }
            if pendingStop { enqueue(IFit.speedFrames(0), "stop (velocidad 0)"); pendingStop = false }
        }
    }

    private func ftmsWrite(_ d: Data, _ label: String) {
        guard let p = peripheral, let c = writeChar else { return }
        addLog(">> \(d.hex)  // FTMS \(label)")
        p.writeValue(d, for: c, type: .withResponse)
    }

    private func reset() {
        pumpTimer?.invalidate(); pumpTimer = nil
        writeTimeout?.cancel(); writeTimeout = nil
        queue.removeAll(); waitingWrite = false
        ready = false; mode = .none; writeChar = nil
        pendingSpeed = nil; pendingIncline = nil; pendingStart = false; pendingStop = false
        // velocidad e inclinación se quedan con el último valor conocido (la UI lo pinta en gris)
    }

    // MARK: log

    func addLog(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        let line = "\(f.string(from: Date())) \(s)"
        log.append(line)
        if log.count > 400 { log.removeFirst(log.count - 400) }
        if let d = (line + "\n").data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile(); h.write(d); try? h.close()
            } else {
                try? d.write(to: logURL)
            }
        }
    }
}

extension Treadmill: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        addLog("bluetooth estado \(c.state.rawValue)")
        guard c.state == .poweredOn else { status = "Bluetooth no disponible"; return }
        if let s = UserDefaults.standard.string(forKey: savedKey), let id = UUID(uuidString: s),
           let p = c.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p)
        } else {
            startScan()
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
        guard let name, !name.isEmpty else { return }
        if let i = devices.firstIndex(where: { $0.id == p.identifier }) {
            devices[i].rssi = rssi.intValue
        } else {
            devices.append(FoundDevice(id: p.identifier, peripheral: p, name: name, rssi: rssi.intValue))
            let svcs = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString).joined(separator: ",") ?? ""
            addLog("visto \(name) rssi \(rssi) servicios [\(svcs)]")
        }
        devices.sort { ($0.looksIFit ? 0 : 1, -$0.rssi) < ($1.looksIFit ? 0 : 1, -$1.rssi) }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        connectedName = p.name
        status = "Conectada; buscando servicios…"
        addLog("conectada")
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        addLog("fallo al conectar: \(error?.localizedDescription ?? "")")
        if !userDisconnected { c.connect(p) }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        addLog("desconectada \(error?.localizedDescription ?? "")")
        reset()
        connectedName = nil
        if userDisconnected {
            status = "Desconectada"
            peripheral = nil
            startScan()
        } else {
            status = "Reconectando…"
            c.connect(p) // CoreBluetooth no caduca: reconecta en cuanto vuelva a verla
        }
    }
}

extension Treadmill: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] {
            addLog("servicio \(s.uuid.uuidString)")
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            addLog("  car. \(c.uuid.uuidString) props \(String(c.properties.rawValue, radix: 16))")
        }
        let hasIFit = p.services?.contains { $0.uuid == IFit.service } ?? false
        if s.uuid == IFit.service {
            mode = .ifit
            writeChar = s.characteristics?.first { $0.uuid == IFit.write }
            if let n = s.characteristics?.first(where: { $0.uuid == IFit.notify }) {
                p.setNotifyValue(true, for: n)
            } else {
                status = "Falta la característica 1535"
            }
        } else if s.uuid == FTMS.service && !hasIFit {
            mode = .ftms
            writeChar = s.characteristics?.first { $0.uuid == FTMS.controlPoint }
            for c in s.characteristics ?? [] where c.uuid == FTMS.treadmillData || c.uuid == FTMS.controlPoint {
                p.setNotifyValue(true, for: c)
            }
            ready = true
            status = "Lista (FTMS)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.ftmsWrite(FTMS.requestControl, "pedir control")
            }
        }
        if p.services?.allSatisfy({ $0.characteristics != nil }) == true && mode == .none {
            status = "Sin servicio iFit ni FTMS"
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        addLog("notificaciones \(c.uuid.uuidString) = \(c.isNotifying) \(error?.localizedDescription ?? "")")
        if c.uuid == IFit.notify && c.isNotifying { runInit() }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let error { addLog("error de escritura \(c.uuid.uuidString): \(error.localizedDescription)") }
        if mode == .ifit { writeDone() }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let d = c.value else { return }
        lastRX = Date()
        if d != lastRawRX { addLog("<< \(d.hex)") }
        lastRawRX = d
        if c.uuid == IFit.notify, let v = IFit.parse(d) {
            speed = v.speed; incline = v.incline
            if v.speed > 0, let s = cachedSpeedAfterStart {
                cachedSpeedAfterStart = nil
                pendingSpeed = s
                addLog("en marcha: aplico \(s)")
            }
        } else if c.uuid == FTMS.treadmillData {
            let v = FTMS.parse(d)
            if let s = v.speed { speed = s }
            if let i = v.incline { incline = i }
        }
    }
}
