import SwiftUI

@main
struct CintaApp: App {
    @State private var treadmill: Treadmill
    @State private var session: Session
    @State private var store = ProgramStore()

    init() {
        let t = Treadmill()
        _treadmill = State(initialValue: t)
        _session = State(initialValue: Session(t: t))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(treadmill)
                .environment(session)
                .environment(store)
                .preferredColorScheme(.dark)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}

struct ContentView: View {
    @Environment(Treadmill.self) private var t

    var body: some View {
        if t.connectedName != nil || t.status.hasPrefix("Reconectando") || ProcessInfo.processInfo.arguments.contains("-demo") {
            MainView()
        } else {
            NavigationStack { DeviceList().navigationTitle("Cinta") }
        }
    }
}

// MARK: pantalla principal

struct MainView: View {
    @Environment(Treadmill.self) private var t
    @Environment(Session.self) private var s
    @State private var showPrograms = false
    @State private var showLog = false

    var body: some View {
        GeometryReader { geo in
            if geo.size.width > geo.size.height {
                // Apaisada: datos a la izquierda, botones a la derecha
                HStack(spacing: 20) {
                    VStack(spacing: 10) {
                        StatusBar(showLog: $showLog)
                        Spacer(minLength: 0)
                        TimeDisplay(size: 120)
                        Metrics()
                        Spacer(minLength: 0)
                        SeriesArea(showPrograms: $showPrograms)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Controls()
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 12) {
                    StatusBar(showLog: $showLog)
                    Spacer(minLength: 0)
                    TimeDisplay(size: 110)
                    Metrics()
                    Spacer(minLength: 0)
                    SeriesArea(showPrograms: $showPrograms)
                    Controls()
                }
            }
        }
        .padding(.horizontal)
        .sheet(isPresented: $showPrograms) { ProgramList() }
        .sheet(isPresented: $showLog) { LogSheet() }
    }
}

struct TimeDisplay: View {
    @Environment(Session.self) private var s
    let size: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            Text(clock(s.elapsed))
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Button { s.resetTime() } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }
}

struct Metrics: View {
    @Environment(Treadmill.self) private var t
    var body: some View {
        HStack {
            Metric(value: t.speed, unit: "km/h", label: "VELOCIDAD")
            Metric(value: t.incline, unit: "%", label: "ALTURA")
        }
        .opacity(t.ready ? 1 : 0.35)
    }
}

struct SeriesArea: View {
    @Environment(Session.self) private var s
    @Binding var showPrograms: Bool
    var body: some View {
        if s.program != nil {
            SeriesCard()
        } else {
            Button { showPrograms = true } label: {
                Label("Series", systemImage: "list.bullet").font(.title3.bold())
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
    }
}

struct Controls: View {
    @Environment(Treadmill.self) private var t
    @Environment(Session.self) private var s
    var body: some View {
        VStack(spacing: 8) {
            ControlRow(label: "ALTURA") {
                Key("−", small: true) { t.setIncline(t.inclineBase - 1) }
                Key("0", small: true) { t.setIncline(0) }
                Key("1", small: true) { t.setIncline(1) }
                Key("+", small: true) { t.setIncline(t.inclineBase + 1) }
            }
            HStack(spacing: 8) {
                Key("−", color: .indigo, big: true) { t.setSpeed(t.speedBase - 0.5) }
                Key("+", color: .indigo, big: true) { t.setSpeed(t.speedBase + 0.5) }
            }
            .padding(.top, 6)
            HStack(spacing: 8) {
                Key("0", color: .red, big: true) { s.manualStop() }
                Key("4", big: true) { t.setSpeed(4) }
                Key("9", big: true) { t.setSpeed(9) }
            }
            .padding(.bottom, 4)
        }
    }
}

struct StatusBar: View {
    @Environment(Treadmill.self) private var t
    @Binding var showLog: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(t.ready ? .green : .orange).frame(width: 9, height: 9)
            Text(t.ready ? "Conectada" : t.status).font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("Registro") { showLog = true }
                Button("Desconectar", role: .destructive) { t.disconnect() }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
        }
        .padding(.top, 4)
    }
}

struct Metric: View {
    let value: Double?
    let unit: String
    let label: String

    var body: some View {
        VStack(spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.map { String(format: "%.1f", $0).replacingOccurrences(of: ".", with: ",") } ?? "—")
                    .font(.system(size: 52, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.title3).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct SeriesCard: View {
    @Environment(Session.self) private var s

    var body: some View {
        VStack(spacing: 8) {
            if s.finished {
                Text("Serie terminada").font(.title2.bold())
                Button("Cerrar") { s.end() }.buttonStyle(.bordered)
            } else if let c = s.current {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading) {
                        Text("\(num(c.step.speed)) km/h" + (c.step.incline.map { " · \(num($0)) %" } ?? ""))
                            .font(.title.bold())
                        Text([c.label, s.next.map { "luego \(num($0.step.speed))" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(clock(s.stepRemaining)).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("quedan \(clock(s.programRemaining))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button(s.paused ? "Seguir" : "Pausa") { s.paused ? s.resume() : s.pause() }
                        .buttonStyle(.borderedProminent).tint(s.paused ? .green : .orange)
                    Button("Saltar") { s.skip() }.buttonStyle(.bordered)
                    Spacer()
                    Button("Terminar", role: .destructive) { s.end() }.buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ControlRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 8) { content }
        }
    }
}

struct Key: View {
    @Environment(Treadmill.self) private var t
    let title: String
    var color: Color = .blue
    var small = false
    var big = false
    let action: () -> Void
    init(_ title: String, color: Color = .blue, small: Bool = false, big: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.color = color; self.small = small; self.big = big; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: big ? 52 : small ? 20 : 34, weight: .bold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, minHeight: big ? 110 : small ? 40 : 70)
        }
        .tint(small ? .gray : color)
        .modifier(KeyStyle(small: small))
        .disabled(!t.ready)
    }
}

private struct KeyStyle: ViewModifier {
    let small: Bool
    func body(content: Content) -> some View {
        if small { content.buttonStyle(.bordered) } else { content.buttonStyle(.borderedProminent) }
    }
}

// MARK: series

struct ProgramList: View {
    @Environment(ProgramStore.self) private var store
    @Environment(Session.self) private var s
    @Environment(\.dismiss) private var dismiss
    @State private var editing: UUID?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.programs) { p in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(p.name).font(.headline)
                        Text("\(clock(Double(p.totalSeconds))) · \(summary(p))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        HStack {
                            Button {
                                s.start(p)
                                dismiss()
                            } label: {
                                Label("Empezar", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent).tint(.green)
                            Button("Editar") { editing = p.id }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { store.programs.remove(atOffsets: $0) }
            }
            .navigationDestination(item: $editing) { id in
                ProgramEditor(program: Binding(
                    get: { store.programs.first { $0.id == id } ?? Program(name: "", blocks: []) },
                    set: { v in if let i = store.programs.firstIndex(where: { $0.id == id }) { store.programs[i] = v } }
                ))
            }
            .navigationTitle("Series")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.programs.append(Program(name: "Nueva", blocks: [Block(repeats: 1, steps: [Step(seconds: 300, speed: 5)])]))
                    } label: { Image(systemName: "plus") }
                }
            }
        }
    }

    private func summary(_ p: Program) -> String {
        p.blocks.map { b in
            let steps = b.steps.map { "\(clock(Double($0.seconds))) a \(num($0.speed))" }.joined(separator: " + ")
            return b.repeats > 1 ? "\(b.repeats)× (\(steps))" : steps
        }.joined(separator: ", ")
    }
}

struct ProgramEditor: View {
    @Binding var program: Program

    static let durations = [15, 30, 45, 60, 90, 120, 180, 240, 300, 360, 420, 480, 540, 600, 720, 900, 1200, 1500, 1800, 2700, 3600]
    static let speeds = stride(from: 0.5, through: 16, by: 0.5).map { $0 }
    static let inclines = stride(from: 0.0, through: 10, by: 1).map { $0 }

    var body: some View {
        Form {
            Section { TextField("Nombre", text: $program.name) }
            ForEach($program.blocks) { $b in
                Section {
                    Stepper("Repetir \(b.repeats)×", value: $b.repeats, in: 1...50)
                    ForEach($b.steps) { $st in
                        HStack {
                            Picker("", selection: $st.seconds) {
                                ForEach(Self.durations, id: \.self) { Text(clock(Double($0))).tag($0) }
                            }
                            .labelsHidden().pickerStyle(.menu)
                            Picker("", selection: $st.speed) {
                                ForEach(Self.speeds, id: \.self) { Text("\(num($0)) km/h").tag($0) }
                            }
                            .labelsHidden().pickerStyle(.menu)
                            Picker("", selection: $st.incline) {
                                Text("altura =").tag(Double?.none)
                                ForEach(Self.inclines, id: \.self) { Text("\(num($0)) %").tag(Double?.some($0)) }
                            }
                            .labelsHidden().pickerStyle(.menu)
                        }
                    }
                    .onDelete { b.steps.remove(atOffsets: $0) }
                    Button("Añadir paso") { b.steps.append(Step(seconds: 60, speed: b.steps.last?.speed ?? 5)) }
                } header: {
                    HStack {
                        Text("Bloque")
                        Spacer()
                        Button("Quitar", role: .destructive) { program.blocks.removeAll { $0.id == b.id } }
                            .font(.caption)
                    }
                }
            }
            Section {
                Button("Añadir bloque") { program.blocks.append(Block(repeats: 1, steps: [Step(seconds: 60, speed: 5)])) }
            }
        }
        .navigationTitle(program.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: conexión y registro

struct DeviceList: View {
    @Environment(Treadmill.self) private var t

    var body: some View {
        List {
            Section { Text(t.status).foregroundStyle(.secondary) }
            Section("Dispositivos (las iFit salen arriba)") {
                ForEach(t.devices) { d in
                    Button { t.connect(d.peripheral) } label: {
                        HStack {
                            Text(d.name).fontWeight(d.looksIFit ? .bold : .regular)
                            Spacer()
                            Text("\(d.rssi) dBm").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
        .toolbar {
            Button(t.scanning ? "Parar" : "Buscar") { t.scanning ? t.stopScan() : t.startScan() }
        }
    }
}

struct LogSheet: View {
    @Environment(Treadmill.self) private var t
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(t.log.suffix(200).reversed().enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Registro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ShareLink(item: t.logFileURL) }
        }
    }
}
