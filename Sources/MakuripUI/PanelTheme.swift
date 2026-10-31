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
    /// 定型文（試作の --k-snippet）。差し込みの札・タブ・見出しの色
    let snippet: Color
    /// コードの配色（試作の --s-kw・--s-str など。Xcode の既定に寄せたもの）
    let syntax: [SyntaxTokenKind: Color]
    var isDark = false

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
        kindAll: hex(0x6E6E73), snippet: hex(0x0B8A98),
        syntax: [
            .keyword: hex(0xAD3DA4), .string: hex(0xC41A16), .comment: hex(0x6C7986), .number: hex(0x272AD8),
            .type: hex(0x703DAA), .function: hex(0x326D74), .attribute: hex(0x815F03), .flag: hex(0x0F68A0),
        ])

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
        kindAll: hex(0xA8A8AE), snippet: hex(0x55D6E3),
        syntax: [
            .keyword: hex(0xFF7AB2), .string: hex(0xFF8170), .comment: hex(0x8A96A3), .number: hex(0xD9C97C),
            .type: hex(0xDABAFF), .function: hex(0x78C2B3), .attribute: hex(0xFFA14F), .flag: hex(0x6BDFFF),
        ], isDark: true)

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

    /// 定型文（試作の吹き出しの線画）
    static let snippet = "text.bubble"

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
    var withinWindow = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = withinWindow ? .withinWindow : .behindWindow
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
    /// 同じ窓の中に重ねる面（⌘E のアプリ選択）。後ろのパネルの中身をぼかして透かす
    var withinWindow = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    switch style {
                    case .live: VisualEffectBackground(withinWindow: withinWindow)
                    case .flat(let backdrop): if !withinWindow { backdrop }
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
            .background {
                // 実機は窓の影（NSWindow.hasShadow）。見比べ用の平らな描画では試作の --shadow を描く
                if case .flat = style {
                    shape.fill(Color.black.opacity(0.01))
                        .shadow(color: .black.opacity(palette.isDark ? 0.75 : 0.34), radius: 26, y: 30)
                        .shadow(color: .black.opacity(palette.isDark ? 0.5 : 0.18), radius: 10, y: 10)
                }
            }
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = 22, withinWindow: Bool = false) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, withinWindow: withinWindow))
    }
}

/// 試作の CSS の文字の指定（大きさ・行の高さ）。SwiftUI には line-height がないので、
/// 書体の本来の行の高さとの差を行間に足し、1 行目の上と最後の行の下に半分ずつ足して同じ高さにする
struct CSSText {
    let size: CGFloat
    /// 行の高さ（pt）。CSS の倍率 × 大きさ
    let lineHeight: CGFloat
    var weight: Font.Weight = .regular
    var mono = false

    init(_ size: CGFloat, lineHeight multiple: CGFloat, weight: Font.Weight = .regular, mono: Bool = false) {
        self.size = size
        self.lineHeight = (size * multiple * 100).rounded() / 100
        self.weight = weight
        self.mono = mono
    }

    /// 等幅は NSFont の SF Mono をそのまま使う（SwiftUI の .monospaced は小さい大きさで字幅が 1 割ほど広くなり、
    /// 試作の行の折り返しとずれるため）
    var font: Font {
        mono
            ? Font(NSFont.monospacedSystemFont(ofSize: size, weight: weight == .semibold ? .semibold : .regular))
            : .system(size: size, weight: weight)
    }

    /// 行の高さの指定がいらないところの等幅
    static func mono(_ size: CGFloat) -> Font {
        Font(NSFont.monospacedSystemFont(ofSize: size, weight: .regular))
    }

    /// 本来の行の高さとの差（大きさごとに 1 回だけ測る）
    var extra: CGFloat {
        max(0, lineHeight - Self.naturalLineHeights.value(size: size, mono: mono))
    }

    private static let naturalLineHeights = NaturalLineHeights()
}

/// 書体の本来の行の高さ（大きさごとに 1 回だけ測る）
private final class NaturalLineHeights: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: CGFloat] = [:]

    func value(size: CGFloat, mono: Bool) -> CGFloat {
        let key = "\(size)-\(mono)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = values[key] { return cached }
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
        let natural = NSLayoutManager().defaultLineHeight(for: font)
        values[key] = natural
        return natural
    }
}

extension View {
    func css(_ style: CSSText) -> some View {
        let extra = style.extra
        return font(style.font).lineSpacing(extra).padding(.vertical, extra / 2)
    }
}

/// 試作の文字の指定（base.css・panel-b.css から。行の高さは body の 1.45 を受け継ぐもの以外を明記）
enum CSS {
    static let cardText = CSSText(13, lineHeight: 1.45)
    /// カードのコード・コマンドは `.pb .card .cb { font-size: 13px }` が効いて 13px の等幅
    static let cardMono = CSSText(13, lineHeight: 1.55, mono: true)
    static let urlTitle = CSSText(13, lineHeight: 1.45, weight: .semibold)
    static let urlDomain = CSSText(11.5, lineHeight: 1.45)
    static let urlPath = CSSText(10.5, lineHeight: 1.45, mono: true)
    static let small = CSSText(11.5, lineHeight: 1.45)
    static let colorHex = CSSText(13, lineHeight: 1.45, mono: true)
    static let group = CSSText(11, lineHeight: 1.45, weight: .semibold)
    static let emptyTitle = CSSText(13.5, lineHeight: 1.45, weight: .semibold)
    static let emptyText = CSSText(12, lineHeight: 1.45)
    static let previewText = CSSText(15, lineHeight: 1.75)
    static let previewRich = CSSText(14.5, lineHeight: 1.7)
    static let previewCommand = CSSText(13, lineHeight: 1.7, mono: true)
    static let previewCode = CSSText(12.5, lineHeight: 1.65, mono: true)
    static let previewURL = CSSText(11.5, lineHeight: 1.5, mono: true)
    static let detailTitle = CSSText(11, lineHeight: 1.45)
    static let detailValue = CSSText(12, lineHeight: 1.45)
    /// 定型文のカード（試作の .cb-snip-name・.cb-snip-body）と ⌘Y の本文（.pv-snippet .snip-body）
    static let snippetName = CSSText(13, lineHeight: 1.45, weight: .semibold)
    static let snippetBody = CSSText(13, lineHeight: 1.45)
    static let previewSnippet = CSSText(14.5, lineHeight: 1.75)
}
