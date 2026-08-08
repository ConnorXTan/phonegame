import SwiftUI

/// Full-bleed viewfinder: the camera *is* the screen. Everything else is a thin
/// overlay — a status strip, the reticle, and the fire button.
struct GameHUDView: View {
    @EnvironmentObject private var engine: GameEngine
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDebug = false
    @State private var showScores = false
    @State private var clockPulse = false

    var body: some View {
        ZStack {
            // What the back of the phone sees — the same ARSession UWB camera
            // assistance is running on, so aim and picture agree.
            CameraFeedView(camera: engine.camera)
            scrim

            if engine.isAlive { aimOverlay }

            VStack(spacing: 6) {
                topBar
                if let alert = engine.rangingAlert {
                    Label(alert, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .padding(8)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
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
            LinearGradient(colors: [.black.opacity(0.6), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 130)
            Spacer()
            LinearGradient(colors: [.clear, .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 180)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Status strip

    private var topBar: some View {
        VStack(spacing: 5) {
            HStack(spacing: 14) {
                Text(engine.myName.displayCallSign.uppercased())
                    .font(.caption.bold())
                Text("\(engine.me?.hp ?? 0)")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(hpColor)
                Spacer()
                matchClock
                Text("K \(engine.me?.kills ?? 0) · D \(engine.me?.deaths ?? 0)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                Button { showScores = true } label: {
                    Image(systemName: "list.number")
                }
                Button { showDebug = true } label: {
                    Image(systemName: "waveform.badge.magnifyingglass")
                }
                Button { engine.leave() } label: {
                    Image(systemName: "xmark.circle")
                }
            }
            .font(.footnote)
            .foregroundStyle(.white)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.black.opacity(0.45))
                    Capsule()
                        .fill(hpColor)
                        .frame(width: geo.size.width * max(0, hpFraction))
                }
                .animation(.easeOut(duration: 0.2), value: hpFraction)
            }
            .frame(height: 5)
        }
        .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
        .padding(.horizontal)
        .padding(.top, 6)
    }

    private var hpFraction: CGFloat {
        CGFloat(engine.me?.hp ?? 0) / CGFloat(max(1, engine.settings.maxHP))
    }

    private var hpColor: Color {
        hpFraction > 0.5 ? .green : hpFraction > 0.25 ? .orange : .red
    }

    /// Turns red and pulses over the last 30 seconds.
    private var matchClock: some View {
        let remaining = engine.matchRemaining
        let urgent = remaining <= 30
        return Label(remaining.clockString, systemImage: "timer")
            .font(.caption.bold().monospacedDigit())
            .foregroundStyle(urgent ? Color.red : Color.white)
            .opacity(urgent && clockPulse ? 0.35 : 1)
            .animation(urgent ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true) : .default,
                       value: clockPulse)
            .onChange(of: urgent) { _, isUrgent in clockPulse = isUrgent }
    }

    private var killFeedView: some View {
        VStack(alignment: .trailing, spacing: 2) {
            ForEach(engine.killFeed.prefix(3)) { event in
                Text("\(event.killer.displayCallSign)  ⚡︎  \(event.victim.displayCallSign)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.7), radius: 2)
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
                .foregroundStyle(locked ? Color.red : Color.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
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

    /// FIRE stays centered; the reload button rides off to the right so the
    /// thumb target never moves.
    private var fireControl: some View {
        ZStack {
            fireButton
            if engine.isAlive && engine.ammo < engine.magazineSize && !engine.isReloading {
                reloadButton
                    .offset(x: 96)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: engine.isReloading)
        .padding(.bottom, 28)
    }

    private var fireButton: some View {
        Button(action: engine.fire) {
            ZStack {
                Circle()
                    .fill(fireFill)
                    .shadow(color: .red.opacity(engine.ammo > 0 && engine.isAlive ? 0.6 : 0), radius: 12)
                    .padding(9)

                AmmoRing(ammo: engine.ammo,
                         capacity: engine.magazineSize,
                         reloadProgress: reloadProgress)

                VStack(spacing: 1) {
                    Text(engine.isReloading ? "RELOAD" : "FIRE")
                        .font(.system(size: engine.isReloading ? 16 : 23,
                                      weight: .black, design: .rounded))
                    Text(engine.isReloading
                         ? String(format: "%.1fs", max(0, engine.reloadRemaining))
                         : "\(engine.ammo)/\(engine.magazineSize)")
                        .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                        .opacity(0.85)
                }
                .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 118, height: 118)
        .disabled(!engine.isAlive || engine.isReloading)
    }

    private var fireFill: Color {
        guard engine.isAlive else { return .gray.opacity(0.7) }
        if engine.isReloading { return .orange.opacity(0.75) }
        return engine.ammo > 0 ? .red.opacity(0.9) : .red.opacity(0.45)
    }

    /// 0…1 while reloading, nil otherwise — drives the ring's refill sweep.
    private var reloadProgress: Double? {
        guard engine.isReloading, engine.settings.reloadDuration > 0 else { return nil }
        return 1 - (engine.reloadRemaining / engine.settings.reloadDuration)
    }

    private var reloadButton: some View {
        Button { engine.startReload() } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(.black.opacity(0.5), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Damage flash

    private var damageOverlay: some View {
        Color.red
            .opacity(engine.damageFlash ? 0.5 : 0)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.25), value: engine.damageFlash)
    }
}

/// The ring around FIRE, one segment per round. Segments go dark left-to-right
/// as you shoot; during a reload they sweep back in so the ring doubles as the
/// reload progress bar.
private struct AmmoRing: View {
    let ammo: Int
    let capacity: Int
    let reloadProgress: Double?

    var body: some View {
        ZStack {
            ForEach(0..<max(1, capacity), id: \.self) { slot in
                AmmoSegment(index: slot, total: max(1, capacity))
                    .stroke(color(for: slot),
                            style: StrokeStyle(lineWidth: 5, lineCap: .butt))
            }
        }
        .animation(.easeOut(duration: 0.12), value: ammo)
    }

    private func color(for slot: Int) -> Color {
        if let progress = reloadProgress {
            // Refill sweep: slots light up as the reload runs.
            let loaded = progress * Double(capacity)
            return Double(slot) < loaded ? .orange : .white.opacity(0.15)
        }
        guard slot < ammo else { return .white.opacity(0.15) }
        // Last two rounds read as a warning without needing the number.
        return ammo <= 2 ? .red : .white.opacity(0.95)
    }
}

/// One arc of the ammo ring, with a gap on each side so rounds stay countable.
private struct AmmoSegment: Shape {
    let index: Int
    let total: Int

    func path(in rect: CGRect) -> Path {
        let slice = 360.0 / Double(total)
        let gap = min(7.0, slice * 0.28)
        let start = -90.0 + Double(index) * slice + gap / 2
        let end = start + slice - gap
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                    radius: min(rect.width, rect.height) / 2 - 2.5,
                    startAngle: .degrees(start),
                    endAngle: .degrees(end),
                    clockwise: false)
        return path
    }
}

/// Laser dot with a scope ring around it. The ring tightens and the ticks snap
/// inward the moment UWB says a live target is inside the aim cone.
private struct ScopeReticle: View {
    let locked: Bool

    private var color: Color { locked ? .red : .white.opacity(0.8) }
    private var ringSize: CGFloat { locked ? 74 : 96 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.8), lineWidth: locked ? 2 : 1)
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
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .shadow(color: .red.opacity(0.9), radius: locked ? 10 : 5)
            Circle()
                .stroke(.white.opacity(0.9), lineWidth: 1)
                .frame(width: 15, height: 15)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.5), radius: 2)
        .scaleEffect(locked ? 1.08 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.6), value: locked)
    }
}
