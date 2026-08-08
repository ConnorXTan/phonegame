import SwiftUI

/// Full-bleed viewfinder: the camera *is* the screen. Everything else is a thin
/// overlay — a status strip, the reticle, and the fire button.
struct GameHUDView: View {
    @EnvironmentObject private var engine: GameEngine
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDebug = false
    @State private var showScores = false
    @State private var clockPulse = false

    /// The fire cluster scales with Dynamic Type as a unit — button, ring, and
    /// labels together — so nothing outgrows the circle it sits in.
    @ScaledMetric(relativeTo: .largeTitle) private var fireDiameter: CGFloat = 118
    @ScaledMetric(relativeTo: .title2) private var fireLabelSize: CGFloat = 23
    @ScaledMetric(relativeTo: .title3) private var reloadLabelSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption2) private var ammoCountSize: CGFloat = 11
    @ScaledMetric(relativeTo: .body) private var reloadGlyphSize: CGFloat = 17
    @ScaledMetric(relativeTo: .largeTitle) private var reloadDiameter: CGFloat = 42
    /// Deliberately wider than the fire button — it's the situational-awareness
    /// display, so it should out-rank the control in the visual hierarchy.
    @ScaledMetric(relativeTo: .largeTitle) private var miniMapDiameter: CGFloat = 150

    /// How long a kill toast lingers, and how many can stack before the oldest
    /// is dropped — a multi-kill flurry must not curtain off the viewfinder.
    private let killToastLifetime: TimeInterval = 10
    private let maxKillToasts = 4

    var body: some View {
        ZStack {
            // What the back of the phone sees — the same ARSession UWB camera
            // assistance is running on, so aim and picture agree.
            CameraFeedView(camera: engine.camera)
            scrim

            if engine.isAlive {
                EnemyHealthbarOverlay()
                aimOverlay
            }

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
                // Minimap left, kill feed right — they share the band under the
                // status strip instead of stacking and eating the viewfinder.
                HStack(alignment: .top, spacing: Space.sm) {
                    MiniMapView()
                        .frame(width: miniMapDiameter, height: miniMapDiameter)
                        .padding(.leading, Space.xs)   // hugs the edge to offset the smaller disc
                    killToasts   // carries its own trailing inset
                }
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
        VStack(spacing: Space.xxs) {   // bar rides tight under the readouts
            // Two clusters: match state hard left, controls hard right. Your
            // own name is one thing you never need reminding of, and the bar
            // below already carries HP — so the numbers take the prime spot.
            HStack(spacing: 0) {
                HStack(spacing: Space.xs) {
                    matchClock
                    Text("K \(engine.me?.kills ?? 0) · D \(engine.me?.deaths ?? 0)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Color.echoTextSecondary)
                        .fixedSize()
                        .accessibilityLabel("\(engine.me?.kills ?? 0) kills, \(engine.me?.deaths ?? 0) deaths")
                    shieldBadge
                }

                Spacer(minLength: Space.sm)

                // Zero spacing between them: each already carries a 44pt
                // target, so extra gap would only push the row wider.
                HStack(spacing: 0) {
                    hudButton("list.number", "Scoreboard") { showScores = true }
                    hudButton("waveform.badge.magnifyingglass", "Ranging diagnostics") { showDebug = true }
                    hudButton("xmark.circle", "Leave match") { engine.leave() }
                }
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
        // Tighter than the usual inset: the 44pt targets end in transparent
        // padding, so the glyphs still sit a comfortable distance from the edge.
        .padding(.horizontal, Space.sm)
        .padding(.top, Space.sm)
    }

    /// A HUD chrome button: `.title3` glyph on the full 44x44 HIG target, so a
    /// player in motion can hit it one-handed. `contentShape` makes the whole
    /// square tappable rather than just the glyph's own bounds.
    private func hudButton(_ symbol: String,
                           _ label: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 44, height: 44)   // HIG minimum touch target
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    /// Shield while damage immunity is running. Ticks on its own clock because
    /// the window lapses on a wall-clock deadline, not on a state change — and
    /// without a visible cue, absorbed shots just read as broken hit detection.
    private var shieldBadge: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let shielded = engine.isInvulnerable(at: context.date)
            Image(systemName: "shield.lefthalf.filled")
                .font(.subheadline)
                .foregroundStyle(Color.echoAccent)
                .opacity(shielded ? 1 : 0)
                .accessibilityLabel(shielded ? "Shielded" : "")
                .accessibilityHidden(!shielded)
        }
        .fixedSize()
    }

    private var hpFraction: CGFloat {
        CGFloat(engine.me?.hp ?? 0) / CGFloat(max(1, engine.settings.maxHP))
    }

    private var hpColor: Color { .echoHealth(hpFraction) }

    /// Turns red and pulses over the last 30 seconds.
    private var matchClock: some View {
        let remaining = engine.matchRemaining
        let urgent = remaining <= 30
        return Label(remaining.clockString, systemImage: "timer")
            .font(.subheadline.bold().monospacedDigit())
            .foregroundStyle(urgent ? Color.echoDanger : Color.echoText)
            .opacity(urgent && clockPulse ? Alpha.muted : 1)
            .animation(urgent ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true) : .default,
                       value: clockPulse)
            .onChange(of: urgent) { _, isUrgent in clockPulse = isUrgent }
            .fixedSize()   // never let "4:50" wrap to two lines when the row tightens
    }

    /// Kills arrive as toasts that stack newest-on-top and retire themselves
    /// after `killToastLifetime`. The old feed was a static list that sat there
    /// all match, so a tag from thirty seconds ago looked exactly like one that
    /// just landed. Expiry is computed from each event's timestamp against a
    /// ticking clock — `killFeed` itself never changes, so nothing here can
    /// disturb the engine's record.
    private var killToasts: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let live = engine.killFeed.filter {
                context.date.timeIntervalSince($0.timestamp) < killToastLifetime
            }
            .prefix(maxKillToasts)

            VStack(alignment: .trailing, spacing: Space.xs) {
                ForEach(Array(live.enumerated()), id: \.element.id) { index, event in
                    killToast(event, isLatest: index == 0)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.35), value: live.map(\.id))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal)
        }
    }

    /// A capsule so the text survives whatever the camera is pointed at; the
    /// newest is bold and full-strength so the freshest tag reads first.
    private func killToast(_ event: KillEvent, isLatest: Bool) -> some View {
        (
            Text(event.killer.displayCallSign)
            + Text("  \(Image(systemName: "bolt.fill"))  ")
            + Text(event.victim.displayCallSign)
        )
        .font(isLatest ? .caption2.bold() : .caption2)
        .foregroundStyle(isLatest ? Color.echoText : Color.echoTextSecondary)
        .lineLimit(1)
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .background(Color.echoBackground.opacity(Alpha.heavy), in: Capsule())
        .accessibilityLabel("\(event.killer.displayCallSign) tagged \(event.victim.displayCallSign)")
    }

    // MARK: - Scope

    /// Dead center of the screen, independent of the HUD stack — the dot marks
    /// boresight, which is straight out the back of the phone.
    private var aimOverlay: some View {
        ZStack {
            ScopeReticle(locked: engine.aimedTarget != nil)
            HitMarkerView(marker: engine.hitMarker)
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

    /// FIRE stays centered; the reload button rides off to the right so the
    /// thumb target never moves.
    private var fireControl: some View {
        ZStack {
            fireButton
            if engine.isAlive && engine.ammo < engine.magazineSize && !engine.isReloading {
                reloadButton
                    .offset(x: fireDiameter * 0.81)   // clear of the ring, tracks its scale
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: engine.isReloading)
        .padding(.bottom, Space.xl)
    }

    private var fireButton: some View {
        Button(action: engine.fire) {
            ZStack {
                Circle()
                    .fill(fireFill)
                    .shadow(color: Color.echoPrimary.opacity(engine.ammo > 0 && engine.isAlive
                                                             ? Alpha.strong : 0), radius: 12)
                    .padding(9)   // inset so the ammo ring reads against the camera, not the fill

                AmmoRing(ammo: engine.ammo,
                         capacity: engine.magazineSize,
                         reloadProgress: reloadProgress)

                VStack(spacing: Space.xxs) {
                    Text(engine.isReloading ? "RELOAD" : "FIRE")
                        .font(.system(size: engine.isReloading ? reloadLabelSize : fireLabelSize,
                                      weight: .black, design: .rounded))
                    Text(engine.isReloading
                         ? String(format: "%.1fs", max(0, engine.reloadRemaining))
                         : "\(engine.ammo)/\(engine.magazineSize)")
                        .font(.system(size: ammoCountSize, weight: .bold, design: .rounded).monospacedDigit())
                        .opacity(Alpha.heavy)
                }
                .foregroundStyle(fireLabelColor)
            }
        }
        .buttonStyle(.plain)
        .frame(width: fireDiameter, height: fireDiameter)
        .disabled(!engine.isAlive || engine.isReloading)
        .accessibilityLabel(engine.isReloading ? "Reloading" : "Fire")
        .accessibilityValue("\(engine.ammo) of \(engine.magazineSize) rounds")
    }

    private var fireFill: Color {
        guard engine.isAlive else { return .echoInert }
        if engine.isReloading { return .echoWarning }
        // Empty still reads as the live control, just drained.
        return engine.ammo > 0 ? .echoPrimary : Color.echoPrimary.opacity(Alpha.muted)
    }

    /// Live and reloading are both light fills, so the label goes dark on them
    /// and light only on the dark disabled slate.
    private var fireLabelColor: Color {
        engine.isAlive ? .echoOnPrimary : .echoText
    }

    /// 0…1 while reloading, nil otherwise — drives the ring's refill sweep.
    private var reloadProgress: Double? {
        guard engine.isReloading, engine.settings.reloadDuration > 0 else { return nil }
        return 1 - (engine.reloadRemaining / engine.settings.reloadDuration)
    }

    private var reloadButton: some View {
        Button { engine.startReload() } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: reloadGlyphSize, weight: .bold))
                .foregroundStyle(Color.echoText)
                .frame(width: reloadDiameter, height: reloadDiameter)
                .background(Color.echoBackground.opacity(Alpha.strong), in: Circle())
                .overlay(Circle().stroke(Color.echoText.opacity(Alpha.muted), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reload")
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

/// The four-tick X that pops at the crosshair the instant a shot lands. Same
/// fixed-geometry chrome as the reticle it sits inside — diagram ticks, not
/// icon art. A kill reads danger-red *and* longer/wider, so the two never rely
/// on hue alone. Driven off `HitMarker.count` so two hits in a row each
/// retrigger instead of the second being swallowed.
private struct HitMarkerView: View {
    let marker: HitMarker

    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 1

    // Geometry, sized to sit inside the locked reticle ring (74pt).
    private var tickLength: CGFloat { marker.isKill ? 16 : 13 }
    private var tickRadius: CGFloat { marker.isKill ? 24 : 20 }

    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { arm in
                Capsule()
                    .fill(marker.isKill ? Color.echoDanger : Color.echoText)
                    .frame(width: 3, height: tickLength)
                    .offset(y: -tickRadius)
                    .rotationEffect(.degrees(Double(arm) * 90 + 45))
            }
        }
        .compositingGroup()
        .shadow(color: Color.echoBackground.opacity(Alpha.heavy), radius: 2)
        .opacity(opacity)
        .scaleEffect(scale)
        .onChange(of: marker) { _, _ in flash() }
        .accessibilityHidden(true)   // the haptic and tick already report the hit
    }

    /// Snap in small and opaque, then bloom outward as it fades. The fade has
    /// to be deferred a cycle: setting opacity 1 and animating it to 0 in one
    /// synchronous block coalesces into a single update, and the marker never
    /// renders visible at all.
    private func flash() {
        opacity = 1
        scale = 0.8
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.26)) {
                opacity = 0
                scale = 1.2
            }
        }
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

    /// The ring sits outside the button's fill, over the camera feed, so these
    /// read against the scrim rather than against the green.
    private func color(for slot: Int) -> Color {
        if let progress = reloadProgress {
            // Refill sweep: slots light up as the reload runs.
            let loaded = progress * Double(capacity)
            return Double(slot) < loaded ? .echoWarning : Color.echoText.opacity(Alpha.subtle)
        }
        guard slot < ammo else { return Color.echoText.opacity(Alpha.subtle) }
        // Last two rounds read as a warning without needing the number.
        return ammo <= 2 ? .echoDanger : .echoText
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
