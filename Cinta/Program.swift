import AudioToolbox
import Foundation
import Observation
import UIKit

struct Step: Codable, Identifiable, Hashable {
    var id = UUID()
    var seconds: Int
    var speed: Double
    var incline: Double? // nil = no la toca
}

struct Block: Codable, Identifiable, Hashable {
    var id = UUID()
    var repeats: Int
    var steps: [Step]
}

struct Program: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var blocks: [Block]

    struct Flat {
        let step: Step
        let label: String? // "Serie 3/8"
    }

    var flat: [Flat] {
        blocks.flatMap { b in
            (1...max(1, b.repeats)).flatMap { r in
                b.steps.map { Flat(step: $0, label: b.repeats > 1 ? "Serie \(r)/\(b.repeats)" : nil) }
            }
        }
    }

    var totalSeconds: Int { flat.reduce(0) { $0 + $1.step.seconds } }

    static let example = Program(name: "Andar y correr 8×", blocks: [
        Block(repeats: 1, steps: [Step(seconds: 300, speed: 5)]),
        Block(repeats: 8, steps: [Step(seconds: 60, speed: 9), Step(seconds: 60, speed: 5)]),
        Block(repeats: 1, steps: [Step(seconds: 300, speed: 5)]),
    ])
}

@Observable
final class ProgramStore {
    var programs: [Program] { didSet { save() } }
    private static let key = "programs"

    init() {
        if let d = UserDefaults.standard.data(forKey: Self.key),
           let p = try? JSONDecoder().decode([Program].self, from: d) {
            programs = p
        } else {
            programs = [.example]
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(programs) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}

/// Tiempo transcurrido y series. Todo lo lleva la app, así que sobrevive a los cortes de Bluetooth.
@Observable
final class Session {
    let t: Treadmill
    var elapsed: TimeInterval = 0
    var program: Program?
    var index = 0
    var stepElapsed: TimeInterval = 0
    var paused = false
    var finished = false

    private var flat: [Program.Flat] = []
    private var last = Date()
    private var timer: Timer?
    private var sawMoving = false
    private var lastBeepSecond = -1

    init(t: Treadmill) {
        self.t = t
        t.onReady = { [weak self] in self?.resync() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Con la conexión cortada vale la última velocidad conocida.
    var moving: Bool { (t.speed ?? 0) > 0 }
    var current: Program.Flat? { flat.indices.contains(index) ? flat[index] : nil }
    var next: Program.Flat? { flat.indices.contains(index + 1) ? flat[index + 1] : nil }
    var stepRemaining: TimeInterval { max(0, Double(current?.step.seconds ?? 0) - stepElapsed) }
    var programRemaining: TimeInterval {
        stepRemaining + flat.dropFirst(index + 1).reduce(0) { $0 + Double($1.step.seconds) }
    }

    func resetTime() { elapsed = 0 }

    func start(_ p: Program) {
        program = p
        flat = p.flat
        index = 0
        stepElapsed = 0
        paused = false
        finished = false
        sawMoving = false
        apply()
    }

    func end() {
        program = nil
        flat = []
        finished = false
    }

    func pause() {
        paused = true
        t.stop()
    }

    func resume() {
        paused = false
        sawMoving = false
        apply()
    }

    func skip() {
        guard program != nil, !finished else { return }
        advance()
    }

    /// Botón 0 o STOP de la app durante una serie: la pausa.
    func manualStop() {
        if program != nil && !finished { paused = true }
        t.stop()
    }

    private func apply() {
        guard let s = current?.step else { return }
        t.setSpeed(s.speed)
        if let i = s.incline { t.setIncline(i) }
    }

    private func advance() {
        index += 1
        stepElapsed = 0
        lastBeepSecond = -1
        if current == nil {
            finished = true
            alert(final: true)
        } else {
            apply()
            alert(final: false)
        }
    }

    private func resync() {
        // Tras reconectar: si la cinta sigue en marcha, vuelve a mandar lo que toca.
        // Si está parada no la arranca (alguien pudo pulsar STOP o quitar la llave).
        guard program != nil, !paused, !finished, moving, let s = current?.step else { return }
        t.addLog("reconectada en serie: reenvío \(s.speed)")
        t.setSpeed(s.speed)
        if let i = s.incline { t.setIncline(i) }
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(last)
        last = now
        if moving { elapsed += dt }

        guard program != nil, !paused, !finished, let s = current?.step else { return }
        if moving {
            sawMoving = true
            stepElapsed += dt // el paso empieza a contar cuando la cinta se mueve
            let left = Int(ceil(Double(s.seconds) - stepElapsed))
            if (1...3).contains(left) && left != lastBeepSecond {
                lastBeepSecond = left
                AudioServicesPlaySystemSound(1103)
            }
            if stepElapsed >= Double(s.seconds) { advance() }
        } else if sawMoving && t.ready {
            // Se ha parado desde la consola (STOP o llave): pausa la serie.
            paused = true
            sawMoving = false
            t.addLog("cinta parada desde fuera: serie en pausa")
        }
    }

    private func alert(final: Bool) {
        AudioServicesPlaySystemSound(final ? 1025 : 1005)
        UINotificationFeedbackGenerator().notificationOccurred(final ? .success : .warning)
    }
}

func clock(_ t: TimeInterval) -> String {
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

func num(_ v: Double) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
}
