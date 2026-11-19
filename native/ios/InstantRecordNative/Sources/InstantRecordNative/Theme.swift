import SwiftUI

/// How the app looks: its colours and the two faces its text is set in. The
/// renderer's stock elements use it, and a hand-written view reads it from
/// the environment (`@Environment(\.theme)`), so the screens Ruby draws and
/// the ones written in SwiftUI look like one app.
///
///     AppView(host: host, theme: .cora)
///
/// The default, `.system`, changes nothing: lists, bars and text are iOS's
/// own. Every size stays a system text style, so Dynamic Type works as before.
public struct Theme {
    /// Behind a screen, and behind a list. Nil leaves the system's.
    public var page: Color?
    /// A list's rows, and a card. Nil leaves the system's.
    public var surface: Color?
    /// A quiet fill: a field, a bubble, the status line. Nil leaves the system's.
    public var fill: Color?
    /// The line between rows and around a field. Nil leaves the system's.
    public var hairline: Color?
    /// Text.
    public var ink: Color = .primary
    /// Quieter text: `tone: "secondary"`.
    public var muted: Color = .secondary
    /// Links, buttons and `tone: "accent"`.
    public var tint: Color = .accentColor
    /// A filled shape that stands out, such as a bubble of your own words.
    public var accent: Color = .accentColor
    /// Text on `accent`.
    public var onAccent: Color = .white
    /// The face of headlines, labels and controls.
    public var ui: Font.Design = .default
    /// The face of running text: a `text` with no style, a field, and
    /// whatever a hand-written view sets in it, such as a message's subject
    /// and body. A view sets a face on the text itself, with
    /// `.fontDesign(theme.reading)` or `.fontDesign(theme.ui)`: set around
    /// a whole screen, one face wins over every other inside it.
    public var reading: Font.Design = .default

    public init() {}

    /// iOS as it comes.
    public static let system = Theme()

    /// Cora's look: warm paper, ink and one blue, flat, with hairlines and
    /// no cool grey. Cora's own typefaces are licensed and are not here. The
    /// system's rounded face stands in for headlines and controls, and its
    /// serif for what is read. In the dark it is the same ramp from the
    /// other end.
    public static let cora: Theme = {
        var theme = Theme()
        theme.page = Color(Cora.page)
        theme.surface = Color(Cora.surface)
        theme.fill = Color(Cora.fill)
        theme.hairline = Color(Cora.hairline)
        theme.ink = Color(Cora.ink)
        theme.muted = Color(Cora.muted)
        theme.tint = Color(Cora.tint)
        theme.accent = Color(Cora.accent)
        theme.onAccent = Color(Cora.onAccent)
        theme.ui = .rounded
        theme.reading = .serif
        return theme
    }()

    /// One colour as 0xRRGGBB, in the light and in the dark.
    struct Shade {
        let light: UInt32
        let dark: UInt32
    }

    /// Cora's tokens. Light: page, white, stone ink, sky-600 for links and
    /// sky-300 as a fill under dark text. Dark: stone-950 page, stone-900
    /// surface, stone-100 ink, sky-300 for links and fills.
    enum Cora {
        static let page = Shade(light: 0xFBF8F2, dark: 0x221E1B)
        static let surface = Shade(light: 0xFFFFFF, dark: 0x2D2824)
        static let fill = Shade(light: 0xF0E9DE, dark: 0x3B3530)
        static let hairline = Shade(light: 0xE2D9CC, dark: 0x4A433C)
        static let ink = Shade(light: 0x302B26, dark: 0xF3EEE6)
        static let muted = Shade(light: 0x6E6456, dark: 0xB8AD9E)
        static let tint = Shade(light: 0x2F6CA3, dark: 0x86B2D9)
        static let accent = Shade(light: 0x86B2D9, dark: 0x86B2D9)
        static let onAccent = Shade(light: 0x221E1B, dark: 0x221E1B)
    }

    #if canImport(UIKit)
    /// The navigation bar's titles are UIKit's to draw. Give them the
    /// theme's face and ink. The system theme leaves them alone.
    func styleBars() {
        guard ui != .default else { return }
        let design: UIFontDescriptor.SystemDesign = ui == .rounded ? .rounded : ui == .serif ? .serif : .default
        func face(_ style: UIFont.TextStyle) -> UIFont {
            let plain = UIFontDescriptor.preferredFontDescriptor(withTextStyle: style).withSymbolicTraits(.traitBold)
            return UIFont(descriptor: plain?.withDesign(design) ?? plain ?? .preferredFontDescriptor(withTextStyle: style), size: 0)
        }
        let bar = UINavigationBar.appearance()
        bar.largeTitleTextAttributes = [.font: face(.largeTitle), .foregroundColor: UIColor(ink)]
        bar.titleTextAttributes = [.font: face(.headline), .foregroundColor: UIColor(ink)]
    }
    #else
    func styleBars() {}
    #endif
}

extension Color {
    /// A colour that follows the light and the dark appearance.
    init(_ shade: Theme.Shade) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: shade.dark) : UIColor(rgb: shade.light) })
        #else
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(rgb: shade.dark) : NSColor(rgb: shade.light) })
        #endif
    }
}

#if canImport(UIKit)
private typealias PlatformColor = UIColor
#else
private typealias PlatformColor = NSColor
#endif

private extension PlatformColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.system
}

public extension EnvironmentValues {
    /// The look the app was given. A hand-written view reads its colours and
    /// faces from here.
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
