# Echo

UWB laser tag for iPhone. SwiftUI, iOS 26+. Camera-assisted aiming over U2-chip ranging.

---

# UI & Design Taste

Rules for any change that touches `Echo/Views/`. These are constraints, not suggestions —
if a rule blocks something the design genuinely needs, say so and ask; don't silently break it.

Grounded in *Refactoring UI* (Wathan & Schoger) and Apple's Human Interface Guidelines.

## Hard rules

**No emoji in the interface.** Not in labels, not in status text, not as icons, not "just as a
small accent." Emoji render differently across OS versions, ignore Dynamic Type and tint, carry
no accessibility label, and read as unfinished. Use SF Symbols. This includes 🏆 🎯 ⚡ ✅ ❌ 🔥 and
every decorative dingbat (⚡︎, ★, ▲) reachable from the character palette.

**No hand-authored vector art.** Do not draw icons with `Path`, `Shape`, bezier curves, or
generated SVG. Every glyph comes from SF Symbols — 6,000+ symbols, weight-matched to SF, free
Dynamic Type scaling, free accessibility labels, free tinting. If no symbol fits, use a text label
instead and flag the gap. Hand-rolled icon art is a reliable tell of machine-generated UI.
(Genuine *data* visualization — the radar sweep, a range arc — is not icon art and is fine as
`Shape`/`Canvas`.)

**No new color literals.** Nothing like `Color(red: 0.25, green: 0, blue: 0)` inline in a view.
Colors come from the token layer (below). One magic literal is a bug; twenty is a redesign.

**No `.font(.system(size:))` for text.** It hard-codes a point size and opts that text out of
Dynamic Type. Use semantic styles (`.title2`, `.headline`, `.caption`) or `@ScaledMetric`.
Fixed sizes are acceptable *only* for fixed-geometry chrome — the reticle, radar tick marks —
where the glyph is a diagram element, not prose.

## Color

Echo's palette is a dark tactical HUD read over a live camera feed. Keep it that way.

Define every color once, in `Assets.xcassets` as a Color Set (with a dark variant) or in a single
`Color+Echo.swift`. Views reference names, never values.

| Token | Role | Notes |
|---|---|---|
| `.echoBackground` | Base surface behind non-camera screens | Near-black, not `#000` |
| `.echoSurface` | Cards, sheets, chips | One step up from background |
| `.echoText` / `.echoTextSecondary` | Primary / supporting copy | Secondary is a *dimmer primary*, not gray |
| `.echoAccent` | Interactive, locked-on, primary action | The one color that means "act" |
| `.echoDanger` | Damage, death, enemy | Currently red — keep it exclusive to harm |
| `.echoSuccess` | Lock acquired, hit confirmed, ready | Currently green |

Rules:

- **One accent.** A second "just for this button" accent destroys the first one's meaning.
- **Semantic colors stay semantic.** Red means harm. If red also means "host" and "selected" and
  "recording," it means nothing. Reach for weight, size, or spacing before reaching for a new hue.
- **Never gray text on a colored background.** Gray on color looks muddy and washed out. Use a
  lighter or darker *tint of the background itself* for de-emphasized text on tinted surfaces.
- **Color is never the only signal.** ~8% of men have some color vision deficiency, and the HUD is
  read in motion, in sunlight, under stress. Pair every color cue with a shape, symbol, position,
  or label. "The dot turns green" is not a lock indicator; "the reticle closes *and* turns green" is.
- **Tint shadows, don't blacken them.** Pure-black shadow at low opacity gives a gray, lifeless
  wash. Use a dark tint of the surface hue.

## Spacing, and hierarchy through space

**Use a fixed scale.** Every gap, pad, and inset comes from:

```
2, 4, 8, 12, 16, 24, 32, 48, 64
```

The scale is deliberately non-linear — adjacent steps must be *visibly* different. Right now the
views use 17 distinct spacing values (2, 3, 4, 5, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 28…);
the difference between 10 and 12 is invisible, so those aren't decisions, they're noise. Round to
the nearest scale step. Same for opacity — pick from `0.05, 0.1, 0.2, 0.4, 0.6, 0.8` rather than
inventing 0.07, 0.12, 0.14, 0.45, 0.55, 0.94.

**Start with too much space, then tighten.** The default failure is cramped, not airy. When a
layout feels wrong and you can't say why, the answer is usually more whitespace.

**Space communicates grouping.** Related things sit close; unrelated things sit far apart. A label
must be nearer to its own value than to the neighboring row — otherwise the eye pairs the wrong
things. Get grouping right with spacing *before* adding a divider or a box.

**Fewer borders.** A border is the heaviest way to separate two things. Try, in order: spacing →
a subtle background shift → a shadow → and only then a hairline. Nested boxes with borders inside
borders are the visual signature of an unedited interface.

**Not everything needs a container.** A card inside a card inside a section is three frames around
one fact.

**Emphasize by de-emphasizing.** To make the ammo counter dominant, dim everything else — don't
scale the counter up until it fights the reticle.

## Typography

- **Hierarchy comes from weight and color first, size second.** Three sizes and two weights beat
  seven sizes. Large-and-bold-and-bright is one emphasis applied three times.
- **Two type families, maximum.** Echo currently mixes `.rounded` and `.monospaced`. That's a fine
  pairing with a clear rule: **monospaced for live numerics** (distance, timers, K/D — anything
  that ticks), **rounded for everything else.** Never both in one line of text.
- **`.monospacedDigit()` on every changing number.** Without it, digits jitter as they update.
  The existing HUD does this — keep it.
- **Don't go below `.caption2`.** If text must be smaller than that to fit, the layout is wrong.
- **Uppercase is a label style, not an emphasis style.** Good for a 2–3 word status chip
  (`LOCKED`, `RELOADING`). Never for a sentence.

## Restraint

- **The HUD sits over a live camera feed.** Every pixel of chrome costs situational awareness.
  Before adding an element, name what the player does with it. If it's "nice to know," it belongs
  in the debug view or the match summary, not the HUD.
- **Default to fewer states on screen.** Progressive disclosure over a dense dashboard.
- **Labels are a last resort.** `K 4 · D 2` beats `Kills: 4, Deaths: 2`. If the value's meaning is
  obvious from format or context, drop the label.
- **Match the platform.** Standard navigation, standard gestures, real safe-area handling. HIG
  compliance is the baseline; the game's personality lives in the HUD and motion, not in
  reinventing a tab bar.

## Accessibility (non-negotiable, not polish)

- Every icon-only control gets an `.accessibilityLabel`. A bare SF Symbol button is invisible to
  VoiceOver.
- Text contrast ≥ 4.5:1 against its actual background — including over the camera feed, which is
  why the HUD carries a vignette/scrim. Keep it.
- Tap targets ≥ 44×44pt. A one-handed player in motion has poor aim.
- Honor `.accessibilityReduceMotion` for screen shake, kill-feed slides, and celebration effects.

## Known debt

Existing violations, for when you're already in the file — fix opportunistically, don't sweep:

- `MatchSummaryView.swift:60-61` — 🏆 emoji ×2
- `DebugRangingView.swift:74` — 🎯 emoji
- `GameHUDView.swift:135` — ⚡︎ in the kill feed
- No color tokens anywhere; raw `Color.red` / `.white` / `.gray` throughout, plus a literal
  `Color(red: 0.25, green: 0, blue: 0)`
- 9 hard-coded `.system(size:)` text sizes (24 → 72) that ignore Dynamic Type
- Unsystematized spacing and opacity ladders (see above)
