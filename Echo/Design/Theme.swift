import SwiftUI

/// The single source of truth for color, spacing, opacity, and corner radius.
///
/// Views reference names from here — never raw literals. A color that only
/// exists at one call site is a bug waiting to drift; a spacing value that
/// isn't on the scale is noise the eye can't resolve anyway.

// MARK: - Color

extension Color {

    // Base palette. Everything else derives from these five.

    /// Primary copy.
    static let echoText = Color.white
    /// The surface everything sits on.
    static let echoBackground = Color.black
    /// Interactive and aimed-at: buttons, the fire control, an acquired lock.
    static let echoPrimary = Color.red
    /// Alive, connected, scored.
    static let echoSecondary = Color.green
    /// Standout non-critical state: placement, urgency, host controls.
    static let echoAccent = Color.orange

    // Derived text weights. Secondary is a dimmer primary, never gray —
    // gray on a tinted or photographic background reads as muddy.

    static let echoTextSecondary = Color.echoText.opacity(Alpha.heavy)
    static let echoTextTertiary = Color.echoText.opacity(Alpha.muted)

    // Surfaces, as tints of the text color over the background.

    static let echoSurface = Color.echoText.opacity(Alpha.surface)
    static let echoHairline = Color.echoText.opacity(Alpha.surface)

    // Semantic. Harm is deliberately its own token rather than an alias of
    // `echoPrimary` — if the brand color ever moves, damage must stay legible
    // as damage.

    static let echoDanger = Color.red
    static let echoWarning = Color.yellow
    /// Disconnected, disabled, out of play.
    static let echoInert = Color.gray
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
