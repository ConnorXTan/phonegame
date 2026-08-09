import SwiftUI
import UIKit

/// LTN's brand typeface. The whole interface is set in `Myfont` (shipped as
/// `fontregular.ttf`, PostScript name `Myfont-Regular`) so the app speaks in one
/// voice rather than the system default.
///
/// `Myfont` ships a single Regular weight. Weight modifiers (`.bold()`,
/// `.weight(.black)`) chained onto these still apply, but resolve to a synthetic
/// bold rather than a designed one — the accepted trade for a single-file face.
/// Semantic styles keep Dynamic Type via `relativeTo:`; the `fixedSize` variant
/// is for geometry whose point size is already resolved (e.g. `@ScaledMetric`),
/// so it isn't scaled twice.
private let appFontName = "Myfont-Regular"
private let appBoldFontName = "Myfont-Bold"

/// The brand face runs optically small, and on the Mac's big screen at
/// desk distance it read smaller still — so the laptop gets a global
/// bump. Phones keep the 1:1 ramp.
private let appScale: CGFloat = ProcessInfo.processInfo.isiOSAppOnMac ? 1.25 : 1.0

extension Font {

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
}

/// UIKit-backed controls never consult SwiftUI's font environment, so the
/// segmented pickers would render their titles in San Francisco while every
/// label around them speaks the brand face. Pushed through the appearance
/// proxy once at launch instead.
enum LTNAppearance {
    static func apply() {
        // 13pt is UISegmentedControl's stock title size; run through
        // UIFontMetrics so segment titles track Dynamic Type like the rest
        // of the interface.
        let metrics = UIFontMetrics(forTextStyle: .footnote)
        func brandFont(_ name: String) -> UIFont {
            let size = 13 * appScale
            let font = UIFont(name: name, size: size) ?? .systemFont(ofSize: size)
            return metrics.scaledFont(for: font)
        }
        let segmented = UISegmentedControl.appearance()
        segmented.setTitleTextAttributes([.font: brandFont(appFontName)], for: .normal)
        // The stock control marks selection with a medium weight; the brand
        // face answers with its designed bold cut.
        segmented.setTitleTextAttributes([.font: brandFont(appBoldFontName)], for: .selected)
    }
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
