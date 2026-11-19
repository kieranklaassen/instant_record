import XCTest
@testable import InstantRecordNative

final class ThemeTests: XCTestCase {
    func testTheSystemThemeLeavesTheSystemsLookAlone() {
        let theme = Theme.system

        XCTAssertNil(theme.page)
        XCTAssertNil(theme.surface)
        XCTAssertNil(theme.fill)
        XCTAssertNil(theme.hairline)
        XCTAssertEqual(.default, theme.ui)
        XCTAssertEqual(.default, theme.reading)
    }

    func testCoraSetsItsPaperAndItsTwoFaces() {
        let theme = Theme.cora

        XCTAssertNotNil(theme.page)
        XCTAssertNotNil(theme.surface)
        XCTAssertEqual(.rounded, theme.ui)
        XCTAssertEqual(.serif, theme.reading)
        XCTAssertEqual(0xFBF8F2, Theme.Cora.page.light)
        XCTAssertEqual(0x221E1B, Theme.Cora.page.dark)
    }

    /// WCAG AA for text is 4.5 to 1. Every pair the renderer and the Inbox's
    /// views put text on holds it, in the light and in the dark.
    func testCorasTextHoldsAAContrastOnEveryGroundItIsSetOn() {
        typealias C = Theme.Cora
        let pairs: [(String, Theme.Shade, Theme.Shade)] = [
            ("ink on page", C.ink, C.page), ("ink on surface", C.ink, C.surface), ("ink on fill", C.ink, C.fill),
            ("muted on page", C.muted, C.page), ("muted on surface", C.muted, C.surface), ("muted on fill", C.muted, C.fill),
            ("tint on page", C.tint, C.page), ("tint on surface", C.tint, C.surface),
            ("text on accent", C.onAccent, C.accent),
        ]
        for (name, text, ground) in pairs {
            XCTAssertGreaterThanOrEqual(contrast(text.light, ground.light), 4.5, name + " in the light")
            XCTAssertGreaterThanOrEqual(contrast(text.dark, ground.dark), 4.5, name + " in the dark")
        }
    }

    private func contrast(_ one: UInt32, _ other: UInt32) -> Double {
        let (lighter, darker) = (max(luminance(one), luminance(other)), min(luminance(one), luminance(other)))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ rgb: UInt32) -> Double {
        let parts = [16, 8, 0].map { shift -> Double in
            let value = Double((rgb >> UInt32(shift)) & 0xFF) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2]
    }
}
