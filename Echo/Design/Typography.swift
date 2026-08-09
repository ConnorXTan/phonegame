import SwiftUI

/// Echo's brand typeface. The whole interface is set in `Myfont` (shipped as
/// `fontregular.ttf`, PostScript name `Myfont-Regular`) so the app speaks in one
/// voice rather than the system default.
///
/// `Myfont` ships a single Regular weight. Weight modifiers (`.bold()`,
/// `.weight(.black)`) chained onto these still apply, but resolve to a synthetic
/// bold rather than a designed one — the accepted trade for a single-file face.
/// Semantic styles keep Dynamic Type via `relativeTo:`; the `fixedSize` variant
/// is for geometry whose point size is already resolved (e.g. `@ScaledMetric`),
/// so it isn't scaled twice.
extension Font {
    /// The brand face runs optically small, and on the Mac's big screen at
    /// desk distance it read smaller still — so the laptop gets a global
    /// bump. Phones keep the 1:1 ramp.
    private static let appScale: CGFloat = ProcessInfo.processInfo.isiOSAppOnMac ? 1.25 : 1.0

    /// The brand face at a semantic text style, scaling with Dynamic Type.
    static func app(_ style: Font.TextStyle) -> Font {
        .custom(appFontName, size: style.defaultSize * appScale, relativeTo: style)
    }

    /// The brand face at an already-resolved point size (no second scaling pass).
    static func app(fixedSize: CGFloat) -> Font {
        .custom(appFontName, fixedSize: fixedSize * appScale)
    }

    /// The bold cut of the brand face. A genuine heavier weight (thickened
    /// outlines shipped as `fontbold.ttf`), not the synthetic bold SwiftUI
    /// applies when `.bold()` is chained on a single-weight face.
    static func appBold(_ style: Font.TextStyle) -> Font {
        .custom(appBoldFontName, size: style.defaultSize * appScale, relativeTo: style)
    }

    /// Bold cut at an already-resolved point size.
    static func appBold(fixedSize: CGFloat) -> Font {
        .custom(appBoldFontName, fixedSize: fixedSize * appScale)
    }

    private static let appFontName = "Myfont-Regular"
    private static let appBoldFontName = "Myfont-Bold"
}

private extension Font.TextStyle {
    /// Point size at the Large content-size category — the anchor each style
    /// scales from, mirroring the system ramp so the hierarchy is unchanged.
    var defaultSize: CGFloat {
        switch self {
        case .largeTitle:  34
        case .title:       28
        case .title2:      22
        case .title3:      20
        case .headline:    17
        case .body:        17
        case .callout:     16
        case .subheadline: 15
        case .footnote:    13
        case .caption:     12
        case .caption2:    11
        @unknown default:  17
        }
    }
}
