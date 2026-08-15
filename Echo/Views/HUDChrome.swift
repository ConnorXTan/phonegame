import SwiftUI

/// Chrome shared by the match HUD and the training range: the edge scrim,
/// the reticle + hit marker at boresight, and the FIRE cluster. One
/// implementation so the trigger feels identical in practice and in play.

/// Just enough darkening at the edges to keep white text legible — the
/// middle of the frame stays untouched.
struct HUDScrim: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Color.ltnBackground.opacity(Alpha.strong), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 130)
            Spacer()
            LinearGradient(colors: [.clear, Color.ltnBackground.opacity(Alpha.strong)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 180)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// FIRE stays centered; the reload button rides off to the right so the
/// thumb target never moves.
struct FireControl: View {
    @EnvironmentObject private var engine: GameEngine
    @State private var fireTriggerHeld = false

    /// The fire cluster scales with Dynamic Type as a unit — button, ring, and
    /// labels together — so nothing outgrows the circle it sits in.
    @ScaledMetric(relativeTo: .largeTitle) private var fireDiameter: CGFloat = 118
    @ScaledMetric(relativeTo: .title2) private var fireLabelSize: CGFloat = 23
    @ScaledMetric(relativeTo: .title3) private var reloadLabelSize: CGFloat = 16
    @ScaledMetric(relativeTo: .largeTitle) private var reloadDiameter: CGFloat = 74

    var body: some View {
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
                .shadow(color: Color.ltnPrimary.opacity(engine.ammo > 0 && engine.isAlive
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
        guard engine.isAlive else { return .ltnInert }
        if engine.isReloading { return .ltnWarning }
        // Empty still reads as the live control, just drained.
        return engine.ammo > 0 ? .ltnPrimary : Color.ltnPrimary.opacity(Alpha.muted)
    }

    /// Live and reloading are both light fills, so the label goes dark on them
    /// and light only on the dark disabled slate.
    private var fireLabelColor: Color {
        engine.isAlive ? .ltnOnPrimary : .ltnText
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
                .background(Color.ltnBackground.opacity(Alpha.strong), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reload")
    }
}

/// The four-tick X that pops at the crosshair the instant a shot lands. Same
/// fixed-geometry chrome as the reticle it sits inside — diagram ticks, not
/// icon art. A kill reads danger-red *and* longer/wider, so the two never rely
/// on hue alone. Driven off `HitMarker.count` so two hits in a row each
/// retrigger instead of the second being swallowed.
struct HitMarkerView: View {
    let marker: HitMarker

    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 1

    // Roughly a third of the locked reticle (74pt, the tighter of the two
    // states). Small enough that the ring and the target inside it stay clear,
    // and paired with the art's central gap — sized to clear the 8pt boresight
    // dot at exactly this frame — so the dot always reads as the center. Shrink
    // this and the ticks start colliding with the dot; the gap has to grow with
    // it. A kill runs one step larger so it stays separable by size and not by
    // its danger-red alone.
    private var markerSize: CGFloat { marker.isKill ? 32 : 28 }

    var body: some View {
        // Template-rendered so the black/red marker art picks up the HUD's own
        // tokens: white for a hit, danger-red for a kill — the same read the
        // drawn ticks had, and legible over any camera frame.
        Image(art: marker.isKill ? .hitMarkerKill : .hitMarker)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(marker.isKill ? Color.ltnDanger : Color.ltnText)
            .frame(width: markerSize, height: markerSize)
            .compositingGroup()
            .shadow(color: Color.ltnBackground.opacity(Alpha.heavy), radius: 2)
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
struct AmmoRing: View {
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
            return Double(slot) < loaded ? .ltnWarning : Color.ltnText.opacity(Alpha.subtle)
        }
        guard slot < ammo else { return Color.ltnText.opacity(Alpha.subtle) }
        // Last two rounds read as a warning without needing the number.
        return ammo <= 2 ? .ltnDanger : .ltnText
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
/// inward the moment a live target sits inside the aim cone.
struct ScopeReticle: View {
    let locked: Bool

    private var color: Color { locked ? .ltnPrimary : Color.ltnText.opacity(Alpha.heavy) }
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
                .fill(Color.ltnPrimary)
                .frame(width: 8, height: 8)
                .shadow(color: Color.ltnPrimary.opacity(Alpha.heavy), radius: locked ? 10 : 5)
        }
        .compositingGroup()
        .shadow(color: Color.ltnBackground.opacity(Alpha.muted), radius: 2)
        .scaleEffect(locked ? 1.08 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.6), value: locked)
    }
}
