import AppKit
import SwiftUI

// Note: this file deliberately avoids `@State`. On Command Line Tools-only setups
// SwiftUI's macro plugin is missing, so local state lives in small ObservableObjects.

// MARK: - Theme

enum Theme {
    static let bgTop = Color(red: 0.12, green: 0.16, blue: 0.29)
    static let bgBottom = Color(red: 0.04, green: 0.06, blue: 0.13)
    static let card = Color.white.opacity(0.06)
    static let cardActive = Color.white.opacity(0.12)
    static let stroke = Color.white.opacity(0.09)
    static let accent = Color(red: 0.27, green: 0.56, blue: 1.0)
    static let secondary = Color.white.opacity(0.55)
    static let speedGradient = LinearGradient(
        colors: [Color(red: 0.30, green: 0.52, blue: 0.95),
                 Color(red: 0.45, green: 0.75, blue: 0.95),
                 Color(red: 0.98, green: 0.70, blue: 0.40)],
        startPoint: .leading, endPoint: .trailing)

    static func airColor(_ level: Int?) -> Color {
        guard let c = PurifierStatus.airQualityRGB(level) else {
            return Color(red: 0.55, green: 0.75, blue: 1.0)
        }
        return Color(red: c.r, green: c.g, blue: c.b)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            background
            VStack(alignment: .leading, spacing: 14) {
                if model.isLoggedIn {
                    DashboardView()
                } else {
                    LoginView()
                }
            }
            .padding(16)
        }
        .frame(width: 340)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
    }

    private var background: some View {
        let tint = Theme.airColor(model.selected?.status?.airQualityLevel)
        return ZStack {
            LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [tint.opacity(model.selected?.status?.isOn == true ? 0.22 : 0.06), .clear],
                           center: UnitPoint(x: 0.5, y: 0.28), startRadius: 0, endRadius: 220)
                .animation(.easeInOut(duration: 0.8), value: model.selected?.status?.isOn)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Login

/// Holds the sign-in fields (an ObservableObject rather than @State; see note at top).
final class LoginForm: ObservableObject {
    @Published var email = ""
    @Published var password = ""
}

struct LoginView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var form = LoginForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "fan")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.pulse, options: .repeating)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LevoitBar").font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text("Sign in with your VeSync account").font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.bottom, 4)

            field { TextField("Email", text: $form.email).textContentType(.username) }
            field { SecureField("Password", text: $form.password).textContentType(.password).onSubmit(signIn) }

            HStack(spacing: 6) {
                Text("Country").foregroundStyle(Theme.secondary)
                TextField("US", text: $model.countryCode)
                    .textFieldStyle(.plain)
                    .frame(width: 34)
                    .padding(.vertical, 3).padding(.horizontal, 6)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
                Spacer()
            }
            .font(.caption)

            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(Color(red: 1, green: 0.5, blue: 0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondary).font(.caption)
                Spacer()
                Button(action: signIn) {
                    HStack(spacing: 6) {
                        if model.isLoading { ProgressView().controlSize(.small).tint(.white) }
                        Text("Sign In").font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(Theme.accent, in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.5), radius: 8, y: 2)
                }
                .buttonStyle(PressableStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(form.email.isEmpty || form.password.isEmpty || model.isLoading)
            }
        }
        .onAppear {
            if form.email.isEmpty { form.email = model.email }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .textFieldStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
    }

    private func signIn() {
        let email = form.email.trimmingCharacters(in: .whitespaces)
        let password = form.password
        guard !email.isEmpty, !password.isEmpty else { return }
        Task { await model.login(email: email, password: password) }
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.purifiers.count > 1 {
            DevicePicker()
        }

        if let purifier = model.selected {
            PurifierPanel(purifier: purifier)
                .id(purifier.id)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else {
            VStack(spacing: 10) {
                Image(systemName: "fan")
                    .font(.system(size: 40, weight: .ultraLight))
                    .foregroundStyle(Theme.secondary)
                    .symbolEffect(.pulse, options: .repeating)
                Text(model.isLoading ? "Finding your purifiers…" : "No Levoit purifiers on this account.")
                    .font(.callout).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        }

        if let error = model.errorMessage {
            Text(error).font(.caption).foregroundStyle(Color(red: 1, green: 0.55, blue: 0.55))
                .fixedSize(horizontal: false, vertical: true)
        }

        Footer()
            .onAppear { Task { await model.refresh() } }
    }
}

struct DevicePicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.purifiers) { p in
                    let selected = p.id == model.selected?.id
                    Button {
                        withAnimation(.snappy) { model.selectedID = p.id }
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(p.status?.isOn == true ? Theme.airColor(p.status?.airQualityLevel) : Theme.secondary)
                                .frame(width: 6, height: 6)
                            Text(p.device.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(selected ? Theme.cardActive : Theme.card, in: Capsule())
                        .overlay(Capsule().stroke(selected ? Color.white.opacity(0.25) : .clear))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }
}

struct Footer: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        UpdateBanner(updater: model.updater)
        HStack(spacing: 10) {
            if let updated = model.lastUpdated {
                Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.pulse, isActive: model.isLoading)
            }
            .buttonStyle(.plain).foregroundStyle(Theme.secondary)
            .help("Refresh")

            if Snapshot.isActive {
                Image(systemName: "ellipsis.circle").foregroundStyle(Theme.secondary)
            } else {
                SettingsMenu(updater: model.updater)
            }
        }
    }
}

struct SettingsMenu: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var updater: Updater

    var body: some View {
        Menu {
            if model.isLoggedIn {
                Text(model.email)
                Button("Sign Out") { model.logout() }
                Divider()
            }
            Text("LevoitBar \(updater.currentVersion)")
            Button("Check for Updates…") { Task { await updater.check() } }
            Toggle("Install Updates Automatically", isOn: Binding(
                get: { updater.autoInstall },
                set: { updater.autoInstall = $0 }
            ))
            Divider()
            Button("Quit LevoitBar") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Shows update progress or an "update available" pill when there's something to say.
struct UpdateBanner: View {
    @ObservedObject var updater: Updater

    var body: some View {
        switch updater.state {
        case .available(let version):
            banner(symbol: "arrow.down.circle.fill", text: "LevoitBar \(version) is available") {
                Button("Install") { Task { await updater.install() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.accent, in: Capsule())
            }
        case .installing(let version):
            banner(symbol: "arrow.triangle.2.circlepath", text: "Installing \(version)…") {
                ProgressView().controlSize(.small)
            }
        case .upToDate:
            banner(symbol: "checkmark.circle", text: "You're up to date (\(updater.currentVersion))") { EmptyView() }
        case .failed(let message):
            banner(symbol: "exclamationmark.triangle", text: "Update check failed: \(message)") { EmptyView() }
        case .idle, .checking:
            EmptyView()
        }
    }

    private func banner<Trailing: View>(symbol: String, text: String,
                                        @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Theme.accent)
            Text(text).font(.system(size: 11)).lineLimit(2)
            Spacer(minLength: 4)
            trailing()
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

// MARK: - Purifier panel

struct PurifierPanel: View {
    @EnvironmentObject var model: AppModel
    let purifier: Purifier

    private var status: PurifierStatus? { purifier.status }
    private var isOn: Bool { status?.isOn ?? false }
    private var canControl: Bool { purifier.isControllable && status != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            PurifierHero(isOn: isOn,
                         level: status.map { max($0.fanLevel, $0.mode == "sleep" ? 1 : 0) } ?? 0,
                         tint: Theme.airColor(status?.airQualityLevel),
                         maxLevel: purifier.caps.fanLevels.upperBound)
                .frame(height: 150)
                .onTapGesture { send(.power(!isOn)) }

            if !purifier.device.isOnline {
                notice("Your purifier is offline. Check it's plugged in and on Wi‑Fi.")
            } else if let error = purifier.error, status == nil {
                notice(error)
            }

            if let status, canControl {
                readout(status)
                SpeedSlider(purifier: purifier, status: status)
                    .disabled(!status.isOn)
                    .opacity(status.isOn ? 1 : 0.4)
                tiles(status)
                    .disabled(!status.isOn)
                    .opacity(status.isOn ? 1 : 0.4)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: status)
    }

    // Header: name, air quality chip, power button
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(purifier.device.name)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "aqi.medium").font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                    Text(purifier.caps.modelName).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    if let label = status?.airQualityLabel, purifier.caps.hasAirQuality {
                        Circle().fill(Theme.airColor(status?.airQualityLevel)).frame(width: 6, height: 6)
                            .shadow(color: Theme.airColor(status?.airQualityLevel), radius: 3)
                        Text(label).font(.system(size: 11, weight: .medium))
                            .contentTransition(.interpolate)
                    }
                }
            }
            Spacer()
            PowerButton(isOn: isOn) { send(.power(!isOn)) }
                .disabled(!canControl)
        }
    }

    private func readout(_ s: PurifierStatus) -> some View {
        HStack(alignment: .bottom) {
            if purifier.caps.hasAirQuality, let pm = s.pm25 {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(pm)")
                        .font(.system(size: 54, weight: .thin, design: .rounded))
                        .contentTransition(.numericText(value: Double(pm)))
                        .monospacedDigit()
                    VStack(alignment: .leading, spacing: 0) {
                        Text("µg/m³").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.airColor(s.airQualityLevel))
                        Text("PM2.5").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(s.isOn ? "\(max(s.fanLevel, 0))" : "–")
                        .font(.system(size: 54, weight: .thin, design: .rounded))
                        .contentTransition(.numericText())
                    Text("fan speed").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
            Spacer()
            if let filter = s.filterLife {
                FilterRing(percent: filter)
            }
        }
    }

    private func tiles(_ s: PurifierStatus) -> some View {
        let mode = PurifierMode(rawValue: s.mode) ?? .manual
        let modes = purifier.caps.modes
        return HStack(spacing: 8) {
            Tile(symbol: mode.symbol, title: "Mode", value: mode.label, active: true, chevron: modes.count > 1) {
                guard let i = modes.firstIndex(of: mode) else { send(.mode(modes.first ?? .manual)); return }
                send(.mode(modes[(i + 1) % modes.count]))
            }
            if modes.contains(.sleep) {
                Tile(symbol: "moon.stars", title: "Sleep", value: mode == .sleep ? "On" : "Off", active: mode == .sleep) {
                    send(.mode(mode == .sleep ? (modes.contains(.auto) ? .auto : .manual) : .sleep))
                }
            }
            Tile(symbol: s.displayOn ? "lightbulb.max" : "lightbulb.slash", title: "Display",
                 value: s.displayOn ? "On" : "Off", active: s.displayOn) {
                send(.display(!s.displayOn))
            }
            Tile(symbol: s.childLock ? "lock.fill" : "lock.open", title: "Lock",
                 value: s.childLock ? "On" : "Off", active: s.childLock) {
                send(.childLock(!s.childLock))
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
    }

    private func send(_ command: PurifierCommand) {
        guard canControl else { return }
        Task { await model.send(command, to: purifier) }
    }
}

// MARK: - Components

struct PowerButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isOn {
                    // Soft breathing halo while running
                    TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        let pulse = (sin(t * 2.2) + 1) / 2
                        Circle()
                            .fill(Theme.accent.opacity(0.25 + 0.2 * pulse))
                            .frame(width: 44 + 10 * pulse, height: 44 + 10 * pulse)
                            .blur(radius: 6)
                    }
                }
                Circle()
                    .fill(isOn
                          ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.38, green: 0.66, blue: 1), Theme.accent],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Theme.card))
                    .overlay(Circle().stroke(isOn ? Color.white.opacity(0.3) : Theme.stroke))
                    .frame(width: 42, height: 42)
                Image(systemName: "power")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isOn ? .white : Theme.secondary)
                    .symbolEffect(.bounce, value: isOn)
            }
            .frame(width: 56, height: 56)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isOn)
        .help(isOn ? "Turn off" : "Turn on")
    }
}

/// Illustrated purifier with animated airflow streaming out of the top vent.
struct PurifierHero: View {
    let isOn: Bool
    let level: Int
    let tint: Color
    let maxLevel: Int

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1 / 45, paused: !isOn)) { ctx in
                Canvas { context, size in
                    guard isOn else { return }
                    drawAirflow(context: context, size: size,
                                time: ctx.date.timeIntervalSinceReferenceDate)
                }
            }
            .transition(.opacity)

            purifierBody
                .offset(y: 26)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .help(isOn ? "Click to turn off" : "Click to turn on")
    }

    private var speed: Double { 0.35 + 0.35 * Double(max(level, 1)) }

    private func drawAirflow(context: GraphicsContext, size: CGSize, time: Double) {
        let vent = CGPoint(x: size.width / 2, y: size.height / 2 - 18)
        let streams = 9
        let intensity = 0.35 + 0.65 * Double(max(level, 1)) / Double(max(maxLevel, 1))

        // Flowing arcs fanning out of the vent
        for i in 0..<streams {
            let f = Double(i) / Double(streams - 1) - 0.5          // -0.5 ... 0.5
            let spread = 120 * f
            var path = Path()
            path.move(to: CGPoint(x: vent.x + 26 * f, y: vent.y))
            path.addCurve(to: CGPoint(x: vent.x + spread * 1.6, y: 4),
                          control1: CGPoint(x: vent.x + 30 * f, y: vent.y - 40),
                          control2: CGPoint(x: vent.x + spread * 1.3, y: 30))
            let dashPhase = CGFloat(-(time * speed * 38).truncatingRemainder(dividingBy: 1000))
            let alpha = (1 - abs(f) * 1.1) * 0.55 * intensity
            context.stroke(path,
                           with: .linearGradient(Gradient(colors: [tint.opacity(alpha), tint.opacity(0)]),
                                                 startPoint: vent, endPoint: CGPoint(x: vent.x, y: 0)),
                           style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [7, 11], dashPhase: dashPhase))
        }

        // Rising particles
        let particles = 26
        for i in 0..<particles {
            let seed = Double(i) * 12.9898
            let offset = (sin(seed) * 43758.5453).truncatingRemainder(dividingBy: 1)
            let phase = (time * speed * 0.32 + abs(offset)).truncatingRemainder(dividingBy: 1)
            let lane = Double(i % 9) / 8 - 0.5
            let x = vent.x + lane * (24 + 150 * phase) + sin(time * 1.3 + seed) * 4
            let y = vent.y - phase * (vent.y + 6)
            let r = 1.0 + 1.2 * (1 - phase)
            let a = sin(phase * .pi) * 0.8 * intensity
            context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                         with: .color(tint.opacity(a)))
        }
    }

    private var purifierBody: some View {
        ZStack(alignment: .top) {
            // Floor shadow
            Ellipse()
                .fill(Color.black.opacity(0.35))
                .frame(width: 86, height: 12)
                .blur(radius: 5)
                .offset(y: 92)

            // Body
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.80)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    // Side shading for a cylindrical look
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(LinearGradient(colors: [.black.opacity(0.18), .clear, .clear, .black.opacity(0.22)],
                                             startPoint: .leading, endPoint: .trailing))
                )
                .overlay(alignment: .bottom) { grille.padding(.bottom, 12) }
                .frame(width: 74, height: 96)

            // Top vent
            Ellipse()
                .fill(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.45)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Ellipse().stroke(Color.white.opacity(0.6), lineWidth: 1.5))
                .frame(width: 66, height: 14)
                .offset(y: 3)

            // Front display glow
            Capsule()
                .fill(isOn ? tint : Color(white: 0.6))
                .frame(width: 14, height: 3)
                .shadow(color: isOn ? tint : .clear, radius: 4)
                .offset(y: 30)
        }
        .saturation(isOn ? 1 : 0.2)
        .brightness(isOn ? 0 : -0.25)
        .animation(.easeInOut(duration: 0.6), value: isOn)
    }

    private var grille: some View {
        HStack(spacing: 4) {
            ForEach(0..<9, id: \.self) { _ in
                Capsule().fill(Color.black.opacity(0.12)).frame(width: 2, height: 40)
            }
        }
    }
}

struct FilterRing: View {
    let percent: Int

    var body: some View {
        let color: Color = percent < 10 ? Color(red: 1, green: 0.45, blue: 0.4)
            : percent < 30 ? Color(red: 1, green: 0.72, blue: 0.3) : Color(red: 0.35, green: 0.85, blue: 0.75)
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 1) {
                Text("Filter").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                Text("\(percent)%").font(.system(size: 13, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText(value: Double(percent)))
            }
            ZStack {
                Circle().stroke(Theme.card, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(percent, 100))) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.6), radius: 3)
                Image(systemName: "aqi.low").font(.system(size: 10)).foregroundStyle(color)
            }
            .frame(width: 32, height: 32)
        }
        .padding(.bottom, 8)
        .help("Filter life remaining")
    }
}

/// Gradient speed slider with a draggable knob that snaps to the model's fan levels.
struct SpeedSlider: View {
    @EnvironmentObject var model: AppModel
    let purifier: Purifier
    let status: PurifierStatus

    private var levels: ClosedRange<Int> { purifier.caps.fanLevels }
    private var isManual: Bool { status.mode == PurifierMode.manual.rawValue }
    private var shownLevel: Int {
        let l = isManual ? status.manualLevel : status.fanLevel
        return min(max(l, levels.lowerBound), levels.upperBound)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                stepButton("minus", to: shownLevel - 1)
                GeometryReader { geo in
                    let knob: CGFloat = 34
                    let span = geo.size.width - knob
                    let steps = CGFloat(max(levels.count - 1, 1))
                    let x = span * CGFloat(shownLevel - levels.lowerBound) / steps

                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.black.opacity(0.35))
                            .overlay(Capsule().stroke(Theme.stroke))
                        Capsule().fill(Theme.speedGradient)
                            .frame(width: x + knob)
                            .opacity(isManual ? 1 : 0.55)
                        // Step dots
                        ForEach(Array(levels), id: \.self) { l in
                            Circle().fill(Color.white.opacity(0.35)).frame(width: 3, height: 3)
                                .offset(x: span * CGFloat(l - levels.lowerBound) / steps + knob / 2 - 1.5)
                        }
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white)
                            .frame(width: knob, height: 30)
                            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                            .overlay(
                                Image(systemName: "fan.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.accent)
                                    .rotationEffect(.degrees(Double(shownLevel) * 45))
                            )
                            .offset(x: x)
                    }
                    .frame(height: 34)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                        let f = (value.location.x - knob / 2) / max(span, 1)
                        let level = levels.lowerBound + Int((max(0, min(1, f)) * steps).rounded())
                        set(level)
                    })
                }
                .frame(height: 34)
                stepButton("plus", to: shownLevel + 1)
            }
            HStack {
                Text("Speed \(levels.lowerBound)").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                Spacer()
                Text(isManual ? "Manual · \(shownLevel)" : "\(status.mode.capitalized) mode")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary)
                    .contentTransition(.interpolate)
                Spacer()
                Text("\(levels.upperBound)").font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 40)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.72), value: shownLevel)
    }

    private func stepButton(_ symbol: String, to level: Int) -> some View {
        Button { set(level) } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Theme.card, in: Circle())
                .overlay(Circle().stroke(Theme.stroke))
        }
        .buttonStyle(PressableStyle())
        .disabled(!levels.contains(level) && isManual)
    }

    private func set(_ level: Int) {
        let clamped = min(max(level, levels.lowerBound), levels.upperBound)
        guard !(isManual && clamped == status.manualLevel) else { return }
        Task { await model.send(.fanLevel(clamped), to: purifier) }
    }
}

struct Tile: View {
    let symbol: String
    let title: String
    let value: String
    let active: Bool
    var chevron = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .light))
                        .foregroundStyle(active ? Theme.accent : Theme.secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(height: 20)
                    Spacer(minLength: 0)
                    if chevron {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.secondary)
                    } else {
                        Circle().fill(active ? Theme.accent : Color.white.opacity(0.2)).frame(width: 5, height: 5)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    Text(value).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        .contentTransition(.interpolate)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? Theme.cardActive : Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(active ? Color.white.opacity(0.14) : Theme.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}
