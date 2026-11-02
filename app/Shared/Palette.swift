import SwiftUI

/// Colour roles of the "Graphite & Amber" system (02.11.2026), resolved from Shared/Colors.xcassets, which app and
/// widget both compile: light, dark and Increase Contrast variants per set. Amber (#FF9F0A) only sits on dark
/// grounds; on light grounds the accent is #C93400. System backgrounds and text levels stay Apple's own.
enum Palette {
    /// Accent: the own place (rank in the menu bar panel and the widget, the own row), the current onboarding step.
    static let accent = Color("AccentColor")
    /// Label on a filled accent or status colour (menu row highlight, step number, change pill).
    static let onAccent = Color("OnAccent")
    /// Primary buttons: graphite with amber in light, amber with graphite in dark.
    static let buttonBackground = Color("ButtonBackground")
    static let buttonText = Color("ButtonText")
    /// Problems the user can act on; always with a symbol.
    static let warning = Color("Warning")
    /// Done, found, running; always with a symbol.
    static let success = Color("Success")
    /// Rising usage in the widget (falling stays green).
    static let trendUp = Color("TrendUp")
    /// The graphite field of the app icon, top to bottom (share card).
    static let fieldGradient = LinearGradient(colors: [Color("FieldGradientTop"), Color("FieldGradientBottom")],
                                              startPoint: .top, endPoint: .bottom)
}

/// Label colour of a primary button (`.borderedProminent` tinted with Palette.buttonBackground). It has to sit on the
/// label: a prominent button paints its own label colour over an outer foregroundStyle. Disabled, the system's own
/// colours stay, so a greyed-out button does not show amber.
struct PrimaryLabel: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        if isEnabled { content.foregroundStyle(Palette.buttonText) } else { content }
    }
}

extension View {
    func primaryLabel() -> some View { modifier(PrimaryLabel()) }
}
