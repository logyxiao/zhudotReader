import AppKit
import SwiftUI

struct ReaderPalette: Equatable {
    let app: Color
    let sidebar: Color
    let sidebarStrong: Color
    let paper: Color
    let canvas: Color
    let text: Color
    let muted: Color
    let faint: Color
    let accent: Color
    let accentDeep: Color
    let accentSoft: Color
    let border: Color

    static func palette(for theme: ReaderTheme) -> ReaderPalette {
        switch theme {
        case .day:
            ReaderPalette(
                app: Color(hex: 0xF8FAF8), sidebar: Color(hex: 0xF2F5F3),
                sidebarStrong: Color(hex: 0xE9EEEB), paper: Color(hex: 0xFFFEFA),
                canvas: Color(hex: 0xEEF2EF), text: Color(hex: 0x1B211E),
                muted: Color(hex: 0x68716C), faint: Color(hex: 0x929A95),
                accent: Color(hex: 0x14975A), accentDeep: Color(hex: 0x245940),
                accentSoft: Color(hex: 0xE3EEE7), border: Color(hex: 0x1F2A24, opacity: 0.12)
            )
        case .protect:
            ReaderPalette(
                app: Color(hex: 0xEDF2EA), sidebar: Color(hex: 0xE5ECE3),
                sidebarStrong: Color(hex: 0xDBE5D9), paper: Color(hex: 0xF6F8EF),
                canvas: Color(hex: 0xE1E9DF), text: Color(hex: 0x1B211E),
                muted: Color(hex: 0x68716C), faint: Color(hex: 0x879087),
                accent: Color(hex: 0x4E855E), accentDeep: Color(hex: 0x315D45),
                accentSoft: Color(hex: 0xDDEADC), border: Color(hex: 0x1F2A24, opacity: 0.12)
            )
        case .parchment:
            ReaderPalette(
                app: Color(hex: 0xF2EEE4), sidebar: Color(hex: 0xEBE6DA),
                sidebarStrong: Color(hex: 0xE0D8CA), paper: Color(hex: 0xFFF9E9),
                canvas: Color(hex: 0xE7E0D3), text: Color(hex: 0x29261F),
                muted: Color(hex: 0x706B60), faint: Color(hex: 0x9B9487),
                accent: Color(hex: 0x507957), accentDeep: Color(hex: 0x3D5D44),
                accentSoft: Color(hex: 0xDCE7DA), border: Color(hex: 0x352F25, opacity: 0.13)
            )
        case .night:
            ReaderPalette(
                app: Color(hex: 0x202020), sidebar: Color(hex: 0x242424),
                sidebarStrong: Color(hex: 0x2C2C2C), paper: Color(hex: 0x1D1D1D),
                canvas: Color(hex: 0x242424), text: Color(hex: 0xD8D4CF),
                muted: Color(hex: 0xAAA59F), faint: Color(hex: 0x77736E),
                accent: Color(hex: 0xA9A096), accentDeep: Color(hex: 0xC6BEB5),
                accentSoft: Color(hex: 0x343330), border: Color.white.opacity(0.10)
            )
        }
    }

    var nsPaper: NSColor { NSColor(paper) }
    var nsText: NSColor { NSColor(text) }
    var nsMuted: NSColor { NSColor(muted) }
    var nsAccent: NSColor { NSColor(accentDeep) }
    var nsScrollerKnob: NSColor { nsMuted.withAlphaComponent(0.34) }
    var nsScrollerKnobActive: NSColor { nsMuted.withAlphaComponent(0.55) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

