import SwiftUI

/// The single source of truth for color, spacing, opacity, and corner radius.
///
/// Views reference names, never values. A color that only exists at one call
/// site is a bug waiting to drift; a spacing value that isn't on the scale is
/// noise the eye can't resolve anyway.

// MARK: - HSL

extension Color {
    /// CSS-style HSL. SwiftUI ships HSB, not HSL, so palette values stay in the
    /// notation they were designed in rather than being hand-translated to RGB.
    init(h: Double, s: Double, l: Double) {
        let hue = (h.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 60
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let rgb: (Double, Double, Double)
        switch hue {
        case ..<1: rgb = (c, x, 0)
        case ..<2: rgb = (x, c, 0)
        case ..<3: rgb = (0, c, x)
        case ..<4: rgb = (0, x, c)
        case ..<5: rgb = (x, 0, c)
        default:   rgb = (c, 0, x)
        }
        self.init(.sRGB, red: rgb.0 + m, green: rgb.1 + m, blue: rgb.2 + m)
    }
}

// MARK: - Color

extension Color {

    // Base palette.

    /// Primary copy.
    static let ltnText = Color(h: 0, s: 0, l: 1.0)
    /// The surface everything sits on.
    static let ltnBackground = Color(h: 231, s: 0.68, l: 0.04)
    /// Interactive and aimed-at: buttons, the fire control, an acquired lock.
    static let ltnPrimary = Color(h: 114, s: 0.80, l: 0.55)
    /// Alive, connected, scored.
    static let ltnSecondary = Color(h: 142, s: 1.0, l: 0.64)
    /// Standout non-critical state: placement, urgency, host controls.
    static let ltnAccent = Color(h: 94, s: 1.0, l: 0.70)

    /// Copy and glyphs sitting *on* a filled primary/secondary/accent surface.
    ///
    /// All three actives are light (L 55–70%), so `ltnText` on top of them
    /// lands near 1.5:1 — illegible. The background color inverts to roughly
    /// 13:1 instead. Any filled control must use this for its label.
    static let ltnOnPrimary = Color.ltnBackground

    // Derived text weights. Secondary is a dimmer primary, never gray — gray on
    // a tinted or photographic background reads as muddy.

    static let ltnTextSecondary = Color.ltnText.opacity(Alpha.heavy)
    static let ltnTextTertiary = Color.ltnText.opacity(Alpha.muted)

    // Surfaces, as tints of the text color over the background.

    static let ltnSurface = Color.ltnText.opacity(Alpha.surface)
    static let ltnHairline = Color.ltnText.opacity(Alpha.surface)

    // Semantic states outside the five-token palette.
    //
    // The palette is entirely white-on-dark plus three greens, which cannot
    // express harm or caution: a green damage flash reads as a reward, and a
    // green warning reads as normal chrome. These three are deliberate,
    // minimal exceptions — do not add a fourth without a similarly hard reason.

    /// Damage, death, enemy.
    static let ltnDanger = Color(h: 0, s: 0.85, l: 0.60)
    /// Recoverable problems: no UWB, ranging degraded.
    static let ltnWarning = Color(h: 45, s: 1.0, l: 0.60)
    /// Disconnected, disabled, out of play. Desaturated to the background's
    /// hue so it reads as absence rather than as another color. Lightness is
    /// set so status dots clear 3:1 against the background (4.3:1) — a darker
    /// slate vanished into it.
    static let ltnInert = Color(h: 231, s: 0.15, l: 0.50)

    /// Powerups: consumable drops on the field and the countdown rings of
    /// running effects — wherever they appear (own HUD, enemy tags, minimap).
    /// A fourth exception hue on purpose: powerups are a genuinely new
    /// category (neither harm, caution, nor absence), every other slot on
    /// the wheel is spoken for, and violet clears the greens, the ally blue,
    /// and the danger red at a glance. Glyph shape still carries WHICH
    /// powerup — the hue only says "powerup".
    static let ltnPowerup = Color(h: 270, s: 1.0, l: 0.72)

    /// Team play: YOUR side. Everything already on the wheel is spoken for —
    /// the three greens mean interactive/alive/accent and red means harm — so
    /// allies take the one hue the HUD hasn't spent. Blue also survives every
    /// common color deficiency against `ltnDanger` red, and clears 7:1 on the
    /// background. Enemies need no token of their own: "enemy" is already
    /// `ltnDanger`'s documented job.
    static let ltnTeamAlly = Color(h: 210, s: 1.0, l: 0.64)

    /// Relationship tint as seen from `mine`: your own team reads ally-blue,
    /// the other side reads enemy-red. A player whose team hasn't arrived yet
    /// renders as an enemy — over-marking a threat is the safe failure.
    static func ltnTeam(_ team: Team?, relativeTo mine: Team?) -> Color {
        team != nil && team == mine ? .ltnTeamAlly : .ltnDanger
    }

    /// Broadcast screens (the Mac) have no side, so the mapping is fixed:
    /// alpha is always blue, bravo always red.
    static func ltnTeamAbsolute(_ team: Team) -> Color {
        team == .alpha ? .ltnTeamAlly : .ltnDanger
    }

    /// The health ramp, shared by the player's own HUD, the spectator rail,
    /// and the floating enemy tags, so the same HP reads the same way wherever
    /// it appears.
    ///
    /// The middle step is `ltnWarning` rather than `ltnAccent` because
    /// accent sits 20° from secondary on the wheel — two greens nobody can
    /// separate at a glance, on an indicator that only gets a glance.
    static func ltnHealth(_ fraction: CGFloat) -> Color {
        fraction > 0.5 ? .ltnSecondary : fraction > 0.25 ? .ltnWarning : .ltnDanger
    }
}

// MARK: - Opacity ladder

/// Fixed steps. Anything between two of these is a difference nobody can see.
enum Alpha {
    /// Dividers and the faintest surface fill.
    static let hairline: Double = 0.05
    /// Card and chip fills.
    static let surface: Double = 0.1
    /// Inactive strokes, resting scrims.
    static let subtle: Double = 0.2
    /// De-emphasized text, light scrim over the camera feed.
    static let muted: Double = 0.4
    /// A scrim heavy enough to guarantee text contrast.
    static let strong: Double = 0.6
    /// Supporting text over a photographic background.
    static let heavy: Double = 0.8
    /// Full-screen state takeovers (death, match end).
    static let opaque: Double = 0.95
}

// MARK: - Spacing scale

/// Non-linear on purpose: adjacent steps must be visibly different, or they
/// aren't decisions. Every gap, pad, and inset comes from here.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

// MARK: - Corner radius

enum Radius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
}
