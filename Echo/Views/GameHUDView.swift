import SwiftUI

/// Full-bleed viewfinder: the camera *is* the screen. Everything else is a thin
/// overlay — a status strip, the reticle, and the fire button.
struct GameHUDView: View {
    @EnvironmentObject private var engine: GameEngine
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDebug = false
    @State private var showScores = false
    @State private var clockPulse = false

    /// The fire control scales with Dynamic Type as a unit — button and label
    /// together — so the label never outgrows the circle.
    @ScaledMetric(relativeTo: .largeTitle) private var fireDiameter: CGFloat = 112
    @ScaledMetric(relativeTo: .title2) private var fireLabelSize: CGFloat = 24

    var body: some View {
        ZStack {
            // What the back of the phone sees — the same ARSession UWB camera
            // assistance is running on, so aim and picture agree.
            CameraFeedView(camera: engine.camera)
            scrim

            if engine.isAlive { aimOverlay }

            VStack(spacing: Space.sm) {
                topBar
                if let alert = engine.rangingAlert {
                    Label(alert, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.echoWarning)
                        .padding(Space.sm)
                        .background(Color.echoBackground.opacity(Alpha.strong),
                                    in: RoundedRectangle(cornerRadius: Radius.sm))
                        .padding(.horizontal)
                }
                killFeedView
                Spacer()
                fireControl
            }

            damageOverlay

            if !engine.isAlive {
                DeathView()
            }
        }
        .statusBarHidden()
        .onAppear { engine.camera.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { engine.camera.resume() }
        }
        .sheet(isPresented: $showDebug) { DebugRangingView() }
        .sheet(isPresented: $showScores) { ScoreboardView() }
    }

    /// Just enough darkening at the edges to keep white text legible — the
    /// middle of the frame stays untouched.
    private var scrim: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Color.echoBackground.opacity(Alpha.strong), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 130)
            Spacer()
            LinearGradient(colors: [.clear, Color.echoBackground.opacity(Alpha.strong)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 180)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Status strip

    private var topBar: some View {
        VStack(spacing: Space.xs) {
            HStack(spacing: Space.md) {
                Text(engine.myName.displayCallSign.uppercased())
                    .font(.caption.bold())
                Text("\(engine.me?.hp ?? 0)")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(hpColor)
                    .accessibilityLabel("\(engine.me?.hp ?? 0) hit points")
                Spacer()
                matchClock
                Text("K \(engine.me?.kills ?? 0) · D \(engine.me?.deaths ?? 0)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.echoTextSecondary)
                    .accessibilityLabel("\(engine.me?.kills ?? 0) kills, \(engine.me?.deaths ?? 0) deaths")
                Button { showScores = true } label: {
                    Image(systemName: "list.number")
                }
                .accessibilityLabel("Scoreboard")
                Button { showDebug = true } label: {
                    Image(systemName: "waveform.badge.magnifyingglass")
                }
                .accessibilityLabel("Ranging diagnostics")
                Button { engine.leave() } label: {
                    Image(systemName: "xmark.circle")
                }
                .accessibilityLabel("Leave match")
            }
            .font(.footnote)
            .foregroundStyle(Color.echoText)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.echoBackground.opacity(Alpha.muted))
                    Capsule()
                        .fill(hpColor)
                        .frame(width: geo.size.width * max(0, hpFraction))
                }
                .animation(.easeOut(duration: 0.2), value: hpFraction)
            }
            .frame(height: 5)
            .accessibilityHidden(true)   // the numeric HP readout above covers this
        }
        .shadow(color: Color.echoBackground.opacity(Alpha.strong), radius: 3, y: 1)
        .padding(.horizontal)
        .padding(.top, Space.sm)
    }

    private var hpFraction: CGFloat {
        CGFloat(engine.me?.hp ?? 0) / CGFloat(max(1, engine.settings.maxHP))
    }

    /// Green to amber to red. The mid step is `echoWarning` rather than
    /// `echoAccent` because accent sits 20° from secondary on the wheel — two
    /// greens that no one can tell apart at a glance, on the one indicator
    /// that has to be read at a glance.
    private var hpColor: Color {
        hpFraction > 0.5 ? .echoSecondary : hpFraction > 0.25 ? .echoWarning : .echoDanger
    }

    /// Turns red and pulses over the last 30 seconds.
    private var matchClock: some View {
        let remaining = engine.matchRemaining
        let urgent = remaining <= 30
        return Label(remaining.clockString, systemImage: "timer")
            .font(.caption.bold().monospacedDigit())
            .foregroundStyle(urgent ? Color.echoDanger : Color.echoText)
            .opacity(urgent && clockPulse ? Alpha.muted : 1)
            .animation(urgent ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true) : .default,
                       value: clockPulse)
            .onChange(of: urgent) { _, isUrgent in clockPulse = isUrgent }
    }

    private var killFeedView: some View {
        VStack(alignment: .trailing, spacing: Space.xxs) {
            ForEach(engine.killFeed.prefix(3)) { event in
                (
                    Text(event.killer.displayCallSign)
                    + Text("  \(Image(systemName: "bolt.fill"))  ")
                    + Text(event.victim.displayCallSign)
                )
                .font(.caption2)
                .foregroundStyle(Color.echoTextSecondary)
                .shadow(color: Color.echoBackground.opacity(Alpha.strong), radius: 2)
                .accessibilityLabel("\(event.killer.displayCallSign) tagged \(event.victim.displayCallSign)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal)
    }

    // MARK: - Scope

    /// Dead center of the screen, independent of the HUD stack — the dot marks
    /// boresight, which is straight out the back of the phone.
    private var aimOverlay: some View {
        ZStack {
            ScopeReticle(locked: engine.aimedTarget != nil)
            statusPill.offset(y: 82)
        }
        .allowsHitTesting(false)
    }

    private var statusPill: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let locked = engine.aimedTarget != nil
            Text(lockLabel)
                .font(.footnote.weight(locked ? .bold : .regular))
                .foregroundStyle(locked ? Color.echoPrimary : Color.echoTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
                .background(Color.echoBackground.opacity(Alpha.muted), in: Capsule())
        }
    }

    private var lockLabel: String {
        guard let target = engine.aimedTarget else {
            return engine.aimHint ?? "point the BACK of the phone at your target"
        }
        let name = target.displayCallSign.uppercased()
        guard let distance = engine.ranging.latestReading(for: target)?.distance else {
            return "LOCKED · \(name)"
        }
        return "LOCKED · \(name) · \(String(format: "%.1f m", distance))"
    }

    // MARK: - Fire button

    private var fireControl: some View {
        Button(action: engine.fire) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let progress = cooldownProgress(at: context.date)
                ZStack {
                    Circle()
                        .fill(engine.isAlive
                              ? Color.echoPrimary
                              : Color.echoInert.opacity(Alpha.strong))
                        .shadow(color: Color.echoPrimary.opacity(progress >= 1 ? Alpha.strong : 0),
                                radius: 12)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(fireLabelColor.opacity(Alpha.heavy),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(Space.xs)
                    Text("FIRE")
                        .font(.system(size: fireLabelSize, weight: .black, design: .rounded))
                        .foregroundStyle(fireLabelColor)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: fireDiameter, height: fireDiameter)
        .disabled(!engine.isAlive)
        .padding(.bottom, Space.xl)
        .accessibilityLabel("Fire")
    }

    /// The enabled fill is a light green and the disabled fill is a dark slate,
    /// so the label has to flip with it to stay readable.
    private var fireLabelColor: Color {
        engine.isAlive ? .echoOnPrimary : .echoText
    }

    private func cooldownProgress(at date: Date) -> CGFloat {
        guard let last = engine.lastFireTime else { return 1 }
        return CGFloat(min(1, date.timeIntervalSince(last) / engine.settings.fireCooldown))
    }

    // MARK: - Damage flash

    private var damageOverlay: some View {
        Color.echoDanger
            .opacity(engine.damageFlash ? Alpha.muted : 0)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.25), value: engine.damageFlash)
    }
}

/// Laser dot with a scope ring around it. The ring tightens and the ticks snap
/// inward the moment UWB says a live target is inside the aim cone.
private struct ScopeReticle: View {
    let locked: Bool

    private var color: Color { locked ? .echoPrimary : Color.echoText.opacity(Alpha.heavy) }
    private var ringSize: CGFloat { locked ? 74 : 96 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(Alpha.heavy), lineWidth: locked ? 2 : 1)
                .frame(width: ringSize, height: ringSize)

            // Ticks at 12/3/6/9, pointing in at the dot.
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: 11)
                    .offset(y: -(ringSize / 2 + 7))
                    .rotationEffect(.degrees(Double(i) * 90))
            }

            // The laser dot itself.
            Circle()
                .fill(Color.echoPrimary)
                .frame(width: 8, height: 8)
                .shadow(color: Color.echoPrimary.opacity(Alpha.heavy), radius: locked ? 10 : 5)
            Circle()
                .stroke(Color.echoText.opacity(Alpha.heavy), lineWidth: 1)
                .frame(width: 15, height: 15)
        }
        .compositingGroup()
        .shadow(color: Color.echoBackground.opacity(Alpha.muted), radius: 2)
        .scaleEffect(locked ? 1.08 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.6), value: locked)
    }
}
