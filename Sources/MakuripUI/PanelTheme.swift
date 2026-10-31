import AppKit
import MakuripCore
import SwiftUI

/// 試作（`makurip-design/ui/shared/base.css`）の色を SwiftUI に写したもの。ライトとダークで値を持つ
struct PanelPalette: Sendable {
    let text: Color
    let text2: Color
    let text3: Color
    let fill1: Color
    let fill2: Color
    let fill3: Color
    let sep: Color
    let accent: Color
    let accentInk: Color
    let accentSoft: Color
    /// 素材の色（試作の --glass。実機ではこの下に NSVisualEffectView のぼかしが入る）
    let glass: Color
    let glassHi: Color
    let well: Color
    let wellLine: Color
    let card: Color
    let kbBg: Color
    let kbLine: Color
    /// 検索語に一致した部分の背景
    let mark: Color
    /// コマンドの先頭の「$ 」
    let prompt: Color
    /// パネルの外枠の細い線（試作の --shadow の先頭の 0.5px）
    let hairline: Color
    let kindColors: [ClipKind: Color]
    let kindAll: Color

    func kind(_ kind: ClipKind?) -> Color {
        guard let kind else { return kindAll }
        return kindColors[kind] ?? kindAll
    }

    static func of(_ scheme: ColorScheme) -> PanelPalette {
        scheme == .dark ? dark : light
    }

    static let light = PanelPalette(
        text: rgba(0, 0, 0, 0.86), text2: rgba(0, 0, 0, 0.56), text3: rgba(0, 0, 0, 0.36),
        fill1: rgba(0, 0, 0, 0.04), fill2: rgba(0, 0, 0, 0.07), fill3: rgba(0, 0, 0, 0.12), sep: rgba(0, 0, 0, 0.09),
        accent: hex(0x0A7AFF), accentInk: hex(0x0062D6), accentSoft: rgba(10, 122, 255, 0.13),
        glass: rgba(246, 246, 249, 0.74), glassHi: rgba(255, 255, 255, 0.8), well: rgba(255, 255, 255, 0.66),
        wellLine: rgba(0, 0, 0, 0.06), card: rgba(255, 255, 255, 0.78), kbBg: rgba(0, 0, 0, 0.055),
        kbLine: rgba(0, 0, 0, 0.1), mark: rgba(255, 190, 0, 0.42), prompt: rgba(0, 0, 0, 0.3),
        hairline: rgba(0, 0, 0, 0.16),
        kindColors: [
            .text: hex(0x6E6E73), .richText: hex(0x5856D6), .image: hex(0xD6245A), .code: hex(0x9440CC),
            .command: hex(0x1A8F42), .url: hex(0x0A6FE8), .file: hex(0xC46A00), .color: hex(0x9A7200),
            .other: hex(0x6E6E73),
        ],
        kindAll: hex(0x6E6E73))

    static let dark = PanelPalette(
        text: rgba(255, 255, 255, 0.92), text2: rgba(255, 255, 255, 0.62), text3: rgba(255, 255, 255, 0.4),
        fill1: rgba(255, 255, 255, 0.06), fill2: rgba(255, 255, 255, 0.1), fill3: rgba(255, 255, 255, 0.16),
        sep: rgba(255, 255, 255, 0.1), accent: hex(0x0A84FF), accentInk: hex(0x5AAEFF),
        accentSoft: rgba(10, 132, 255, 0.26), glass: rgba(34, 34, 38, 0.7), glassHi: rgba(255, 255, 255, 0.13),
        well: rgba(255, 255, 255, 0.05), wellLine: rgba(255, 255, 255, 0.07), card: rgba(255, 255, 255, 0.075),
        kbBg: rgba(255, 255, 255, 0.09), kbLine: rgba(255, 255, 255, 0.13), mark: rgba(255, 204, 0, 0.36),
        prompt: rgba(255, 255, 255, 0.36), hairline: rgba(0, 0, 0, 0.7),
        kindColors: [
            .text: hex(0xA8A8AE), .richText: hex(0x9D9BFF), .image: hex(0xFF6B96), .code: hex(0xCF8BFF),
            .command: hex(0x4CD774), .url: hex(0x5AAEFF), .file: hex(0xFFAF4D), .color: hex(0xFFD42E),
            .other: hex(0xA8A8AE),
        ],
        kindAll: hex(0xA8A8AE))

    static func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }

    static func hex(_ value: UInt32) -> Color {
        rgba(Double((value >> 16) & 0xFF), Double((value >> 8) & 0xFF), Double(value & 0xFF), 1)
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = PanelPalette.light
}

/// 素材の描き方。実機はぼかし（NSVisualEffectView）、オフスクリーン描画の検証では平らな背景に重ねる
enum PanelSurfaceStyle {
    case live
    /// 試作のスクショと見比べるとき。`backdrop` は試作側でぼかしを切って敷いた色と同じにする
    case flat(backdrop: Color)
}

private struct SurfaceStyleKey: EnvironmentKey {
    static let defaultValue = PanelSurfaceStyle.live
}

extension EnvironmentValues {
    var palette: PanelPalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }

    var surfaceStyle: PanelSurfaceStyle {
        get { self[SurfaceStyleKey.self] }
        set { self[SurfaceStyleKey.self] = newValue }
    }
}

/// 種類・コピー方法のアイコン（試作の線画を SF Symbols に置き換えたもの）
enum PanelSymbols {
    static func kind(_ kind: ClipKind?) -> String {
        switch kind {
        case nil: "square.grid.2x2"
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .image: "photo"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .command: "apple.terminal"
        case .url: "link"
        case .file: "doc"
        case .color: "paintpalette"
        case .other: "square.dashed"
        }
    }

    static func method(_ method: CopyMethod) -> String {
        switch method {
        case .keyboard: "keyboard"
        case .other: "cursorarrow.click"
        case .unknown: "questionmark.circle"
        }
    }

    static func methodFilter(_ filter: CopyMethodFilter) -> String {
        switch filter {
        case .all: "tray"
        case .keyboard: "keyboard"
        case .other: "cursorarrow.click"
        }
    }
}

/// 種類の名前（タブ・見出し）。試作の Mk.KINDS と同じ
enum KindNames {
    static func label(_ kind: ClipKind?) -> String {
        kind?.label ?? "すべて"
    }
}

/// 背景のぼかし（実機用）。パネルはアクティブでないアプリの窓なので、state を .active に固定する
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// パネルとプレビューの外側（素材・角丸・縁の光）
struct GlassSurface: ViewModifier {
    @Environment(\.palette) private var palette
    @Environment(\.surfaceStyle) private var style
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    switch style {
                    case .live: VisualEffectBackground()
                    case .flat(let backdrop): backdrop
                    }
                    palette.glass
                }
                .clipShape(shape)
            }
            .overlay {
                // 試作の inset 0 1px 0 glass-hi と inset 0 0 0 .5px glass-hi、外側の 0.5px の線
                ZStack {
                    shape.strokeBorder(palette.glassHi, lineWidth: 0.5)
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [palette.glassHi, .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.06)),
                        lineWidth: 1)
                    shape.strokeBorder(palette.hairline, lineWidth: 0.5).padding(-0.5)
                }
                .allowsHitTesting(false)
            }
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = 22) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius))
    }
}
