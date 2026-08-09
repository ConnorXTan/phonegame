import SwiftUI

/// Full-bleed viewfinder: the camera *is* the screen. Everything else is a thin
/// overlay — a status strip, the reticle, and the fire button.
struct GameHUDView: View {
    @EnvironmentObject private var engine: GameEngine
    @Environment(\.scenePhase) private var scenePhase
    @State private var showScores = false
    @State private var clockPulse = false
    @State private var fireTriggerHeld = false

    /// The fire cluster scales with Dynamic Type as a unit — button, ring, and
    /// labels together — so nothing outgrows the circle it sits in.
    @ScaledMetric(relativeTo: .largeTitle) private var fireDiameter: CGFloat = 118
    @ScaledMetric(relativeTo: .title2) private var fireLabelSize: CGFloat = 23
    @ScaledMetric(relativeTo: .title3) private var reloadLabelSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption2) private var killSkullSize: CGFloat = 13
    /// Fixed-geometry heart gauge in the status strip.
    @ScaledMetric(relativeTo: .footnote) private var heartSize: CGFloat = 16
    @ScaledMetric(relativeTo: .largeTitle) private var reloadDiameter: CGFloat = 74
    /// Deliberately wider than the fire button — it's the situational-awareness
    /// display, so it should out-rank the control in the visual hierarchy.
    /// Width only: the map is a forward fan, so height follows its aspect.
    @ScaledMetric(relativeTo: .largeTitle) private var miniMapWidth: CGFloat = 150

    /// How long a kill toast lingers, and how many can stack before the oldest
    /// is dropped — a multi-kill flurry must not curtain off the viewfinder.
    private let killToastLifetime: TimeInterval = 10
    /// Tail of the lifetime spent fading, so it reaches zero exactly at 10 s.
    private let killToastFadeDuration: TimeInterval = 2.5
    private let maxKillToasts = 4

    var body: some View {
        ZStack {
            // What the back of the phone sees — the same ARSession UWB camera
            // assistance is running on, so aim and picture agree.
            CameraFeedView(camera: engine.camera)
            scrim

            if engine.isAlive {
                EnemyHealthbarOverlay()
                ConsumableOverlay()
                aimOverlay
            }

            VStack(spacing: Space.sm) {
                topBar
                if let alert = engine.rangingAlert {
                    Label(alert, systemImage: "exclamationmark.triangle.fill")
                        .font(.app(.caption2))
                        .foregroundStyle(Color.echoWarning)
                        .padding(Space.sm)
                        .background(Color.echoBackground.opacity(Alpha.strong),
                                    in: RoundedRectangle(cornerRadius: Radius.sm))
                        .padding(.horizontal)
                }
                // Minimap left; hearts then kill feed right — they share the band
                // under the status strip instead of stacking and eating the
                // viewfinder.
                HStack(alignment: .top, spacing: Space.sm) {
                    MiniMapView()
                        .frame(width: miniMapWidth, height: miniMapWidth * MiniMapView.aspect)
                        .padding(.leading, Space.xs)   // hugs the edge to offset the smaller fan
                    VStack(alignment: .trailing, spacing: Space.sm) {
                        heartGauge
                        if !engine.activeEffects.isEmpty {
                            effectBadges
                        }
                        killToasts
                    }
                    // Flush with the 28pt glyphs inside their 48pt targets above.
                    .padding(.trailing, Space.xl)
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
        // Clock hard left, controls hard right, score dead center — the score
        // rides an overlay so it centers on the bar itself rather than on
        // whatever width the side clusters happen to have.
        HStack(spacing: 0) {
            HStack(spacing: Space.xs) {
                matchClock
                shieldBadge
            }

            Spacer(minLength: Space.sm)

            // Zero spacing between them: each already carries a 48pt target,
            // so extra gap would only push the row wider.
            HStack(spacing: 0) {
                hudArtButton(.leaderboard, "Leaderboard") { showScores = true }
                hudArtButton(.exitGame, "Leave match") { engine.leave() }
            }
        }
        .overlay {
            // Team play: the score that decides the match outranks a personal
            // K/D (which still lives in the scoreboard).
            if engine.settings.teamPlay {
                teamScore
            } else {
                Text("K \(engine.me?.kills ?? 0) · D \(engine.me?.deaths ?? 0)")
                    .font(.app(.subheadline).monospacedDigit())
                    .foregroundStyle(Color.echoTextSecondary)
                    .fixedSize()
                    .accessibilityLabel("\(engine.me?.kills ?? 0) kills, \(engine.me?.deaths ?? 0) deaths")
            }
        }
        .font(.app(.subheadline))
        .foregroundStyle(Color.echoText)
        .shadow(color: Color.echoBackground.opacity(Alpha.strong), radius: 3, y: 1)
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.sm)
    }

    /// The health gauge rides the right column, directly under the leaderboard
    /// and exit glyphs — it lines the gauge up with the chrome it belongs to and
    /// clears the left column so the minimap can start a row higher.
    private var heartGauge: some View {
        HeartBar(fraction: hpFraction, total: engine.myRole.maxHP, size: heartSize)
            .shadow(color: Color.echoBackground.opacity(Alpha.strong), radius: 3, y: 1)
            .accessibilityElement()
            .accessibilityLabel("Health")
            .accessibilityValue("\(engine.me?.hp ?? 0) of \(engine.myRole.maxHP)")
    }

    /// A HUD chrome button: `.title3` glyph on the full 44x44 HIG target, so a
    /// player in motion can hit it one-handed. `contentShape` makes the whole
    /// square tappable rather than just the glyph's own bounds.
    private func hudButton(_ symbol: String,
                           _ label: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.app(.title3))
                .frame(width: 44, height: 44)   // HIG minimum touch target
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    /// The same 44pt chrome target as `hudButton`, but fronted by a hand-drawn
    /// brand mark instead of an SF Symbol.
    private func hudArtButton(_ art: Art,
                              _ label: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(art: art)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)   // glyph inside the 48pt target
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    /// Your side's kills against theirs, yours first — the "am I winning"
    /// glance. Letters echo the team names; color pairs with position so the
    /// readout survives color-deficient vision.
    private var teamScore: some View {
        let mine = engine.myTeam ?? .alpha
        let theirs = mine.other
        let myKills = engine.teamKills(mine)
        let theirKills = engine.teamKills(theirs)
        return (
            Text("\(mine.initial) \(myKills)")
                .foregroundStyle(Color.echoTeamAlly)
            + Text(" · ")
                .foregroundStyle(Color.echoTextTertiary)
            + Text("\(theirs.initial) \(theirKills)")
                .foregroundStyle(Color.echoDanger)
        )
        .font(.appBold(.subheadline).monospacedDigit())
        .fixedSize()
        .accessibilityLabel("Team \(mine.displayName) \(myKills), team \(theirs.displayName) \(theirKills)")
    }

    /// Shield while damage immunity is running. Ticks on its own clock because
    /// the window lapses on a wall-clock deadline, not on a state change — and
    /// without a visible cue, absorbed shots just read as broken hit detection.
    private var shieldBadge: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let shielded = engine.isInvulnerable(at: context.date)
            Image(systemName: "shield.lefthalf.filled")
                .font(.app(.headline))
                .foregroundStyle(Color.echoAccent)
                .opacity(shielded ? 1 : 0)
                .accessibilityLabel(shielded ? "Shielded" : "")
                .accessibilityHidden(!shielded)
        }
        .fixedSize()
    }

    private var hpFraction: CGFloat {
        CGFloat(engine.me?.hp ?? 0) / CGFloat(max(1, engine.myRole.maxHP))
    }

    /// Running consumable effects, right under the health gauge: each is its
    /// glyph ringed by the time it has left. The ring IS the countdown — at
    /// this size a ticking numeral would be noise.
    private var effectBadges: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            HStack(spacing: Space.sm) {
                ForEach(engine.activeEffects) { effect in
                    if effect.until > context.date {
                        EffectBadge(effect: effect, at: context.date)
                    }
                }
            }
        }
    }

    /// Turns red and pulses over the last 30 seconds.
    private var matchClock: some View {
        let remaining = engine.matchRemaining
        let urgent = remaining <= 30
        return Text(remaining.clockString)
            .font(.appBold(.headline).monospacedDigit())
            .foregroundStyle(urgent ? Color.echoDanger : Color.echoText)
            .accessibilityLabel("Match time \(remaining.clockString)")
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
        // 0.1 s, matching the other HUD clocks: the fade is driven frame by
        // frame from each toast's age rather than by a removal transition,
        // which inside a TimelineView fires against a view the closure has
        // already rebuilt and so pops instead of fading.
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let live = engine.killFeed.filter {
                context.date.timeIntervalSince($0.timestamp) < killToastLifetime
            }
            .prefix(maxKillToasts)

            VStack(alignment: .trailing, spacing: Space.xs) {
                ForEach(Array(live.enumerated()), id: \.element.id) { index, event in
                    killToast(event, isLatest: index == 0)
                        .opacity(fadeOpacity(for: event, at: context.date))
                }
            }
            .animation(.easeOut(duration: 0.25), value: live.map(\.id))
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Solid for most of its life, then a linear ramp to fully transparent
    /// right on the lifetime — a toast that dimmed the whole time would be
    /// half-legible for most of the window it exists to be read in.
    private func fadeOpacity(for event: KillEvent, at now: Date) -> Double {
        let remaining = killToastLifetime - now.timeIntervalSince(event.timestamp)
        guard remaining < killToastFadeDuration else { return 1 }
        return max(0, remaining / killToastFadeDuration)
    }

    /// A capsule so the text survives whatever the camera is pointed at; the
    /// newest is bold and full-strength so the freshest tag reads first. In
    /// team play each name carries its side's tint.
    private func killToast(_ event: KillEvent, isLatest: Bool) -> some View {
        HStack(spacing: Space.xs) {
            Text(event.killer.displayCallSign)
                .foregroundStyle(toastNameColor(event.killer, isLatest: isLatest))
            Image(art: .killSkull)
                .resizable()
                .scaledToFit()
                .frame(height: killSkullSize)
            Text(event.victim.displayCallSign)
                .foregroundStyle(toastNameColor(event.victim, isLatest: isLatest))
        }
        .font(isLatest ? .appBold(.caption2) : .app(.caption2))
        .lineLimit(1)
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .background(Color.echoBackground.opacity(Alpha.heavy), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(event.killer.displayCallSign) tagged \(event.victim.displayCallSign)")
    }

    private func toastNameColor(_ name: String, isLatest: Bool) -> Color {
        guard engine.settings.teamPlay else {
            return isLatest ? .echoText : .echoTextSecondary
        }
        return .echoTeam(engine.players[name]?.team, relativeTo: engine.myTeam)
    }

    // MARK: - Scope

    /// Dead center of the screen, independent of the HUD stack — the dot marks
    /// boresight, which is straight out the back of the phone. The lock reads
    /// off the reticle itself (it closes *and* turns green) plus the enemy
    /// healthbar, so no caption sits under it stealing viewfinder.
    private var aimOverlay: some View {
        ZStack {
            ScopeReticle(locked: engine.aimedTarget != nil)
            HitMarkerView(marker: engine.hitMarker)
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Aim")
        .accessibilityValue(lockDescription)
    }

    /// VoiceOver's version of the lock caption — the sighted read is the
    /// reticle's own geometry, but a screen-reader player still needs the words.
    private var lockDescription: String {
        guard let target = engine.aimedTarget else {
            return engine.aimHint ?? "No target"
        }
        guard let distance = engine.ranging.latestReading(for: target)?.distance else {
            return "Locked on \(target.displayCallSign)"
        }
        return "Locked on \(target.displayCallSign), \(String(format: "%.1f meters", distance))"
    }

    // MARK: - Fire button

    /// FIRE stays centered; the reload button rides off to the right so the
    /// thumb target never moves.
    private var fireControl: some View {
        ZStack {
            fireButton
            if engine.isAlive && engine.ammo < engine.magazineSize && !engine.isReloading {
                reloadButton
                    .offset(x: fireDiameter * 0.9)   // clear of the ring, tracks its scale
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: engine.isReloading)
        .padding(.bottom, Space.xl)
    }

    /// Not a Button: FIRE is press-and-hold — automatic roles keep shooting
    /// while it's held — so the control tracks the touch itself. A press
    /// while dead or reloading is a no-op via engine.fire()'s own guards.
    private var fireButton: some View {
        ZStack {
            Circle()
                .fill(fireFill)
                .shadow(color: Color.echoPrimary.opacity(engine.ammo > 0 && engine.isAlive
                                                         ? Alpha.strong : 0), radius: 12)
                .padding(9)   // inset so the ammo ring reads against the camera, not the fill

            AmmoRing(ammo: engine.ammo,
                     capacity: engine.magazineSize,
                     reloadProgress: reloadProgress)

            // One word, centered. The count lives in the ring around the button
            // — printing it again inside was the same fact twice.
            Text(engine.isReloading ? "RELOAD" : "FIRE")
                .font(.appBold(fixedSize: engine.isReloading ? reloadLabelSize : fireLabelSize))
                .foregroundStyle(fireLabelColor)
        }
        .frame(width: fireDiameter, height: fireDiameter)
        .contentShape(Circle())
        .scaleEffect(fireTriggerHeld && engine.isAlive ? 0.94 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: fireTriggerHeld)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !fireTriggerHeld else { return }
                    fireTriggerHeld = true
                    engine.triggerDown()
                }
                .onEnded { _ in
                    fireTriggerHeld = false
                    engine.triggerUp()
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(engine.isReloading ? "Reloading" : "Fire")
        .accessibilityValue("\(engine.ammo) of \(engine.magazineSize) rounds")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { engine.fire() }
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
    /// Denominator is the duration this reload actually started with, so a
    /// drink lapsing mid-reload can't make the sweep jump.
    private var reloadProgress: Double? {
        guard engine.isReloading, engine.reloadTotal > 0 else { return nil }
        return 1 - (engine.reloadRemaining / engine.reloadTotal)
    }

    private var reloadButton: some View {
        Button { engine.startReload() } label: {
            Image(art: .reload)
                .resizable()
                .scaledToFit()
                .padding(Space.xs)
                .frame(width: reloadDiameter, height: reloadDiameter)
                // Scrim only — the art already draws its own ring, so a stroke
                // here was a second circle around the first.
                .background(Color.echoBackground.opacity(Alpha.strong), in: Circle())
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

/// One of OUR running effects: the shared ring badge at HUD size, which is
/// the one place it scales with Dynamic Type — the same badge on enemy tags
/// stays fixed-geometry like the tag it rides.
private struct EffectBadge: View {
    let effect: ActiveEffect
    let at: Date

    @ScaledMetric(relativeTo: .footnote) private var diameter: CGFloat = 30

    private var fraction: Double {
        guard effect.duration > 0 else { return 0 }
        return effect.until.timeIntervalSince(at) / effect.duration
    }

    var body: some View {
        EffectRingBadge(kind: effect.kind, fraction: fraction, diameter: diameter)
            .accessibilityElement()
            .accessibilityLabel(effect.kind.label)
            .accessibilityValue("\(max(0, Int(effect.until.timeIntervalSince(at).rounded(.up)))) seconds left")
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

    // Half the locked reticle (74pt, the tighter of the two states): the marker
    // reads instantly but leaves the ring — and whatever you're shooting at
    // inside it — clear. A kill runs one step larger so it stays separable by
    // size as well as by its danger-red, never on hue alone. The flash blooms to
    // 1.2x, so these peak at 44.4 and 51.6 — still well inside the ring.
    private var markerSize: CGFloat { marker.isKill ? 43 : 37 }

    var body: some View {
        // Template-rendered so the black/red marker art picks up the HUD's own
        // tokens: white for a hit, danger-red for a kill — the same read the
        // drawn ticks had, and legible over any camera frame.
        Image(art: marker.isKill ? .hitMarkerKill : .hitMarker)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(marker.isKill ? Color.echoDanger : Color.echoText)
            .frame(width: markerSize, height: markerSize)
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
        }
        .compositingGroup()
        .shadow(color: Color.echoBackground.opacity(Alpha.muted), radius: 2)
        .scaleEffect(locked ? 1.08 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.6), value: locked)
    }
}
