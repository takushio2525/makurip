import AppKit
import MakuripCore
import SwiftUI

/// キーの表示（試作の .kb）。Return は記号で出す
struct KeyChip: View {
    enum Style {
        /// ヒント・見出しの横
        case normal
        /// 絞り込みボタンの中（少し小さい）
        case small
        /// カードの番号
        case card
        /// ⌘ を押している間のカードの番号
        case cardHeld
        /// 選んでいるカードの番号
        case cardSelected
        /// 設定画面の「未設定」（試作の .kb-none）
        case none
        /// 設定画面の重なったキー（試作に無い）
        case warning
    }

    let modifiers: String
    let key: String
    var isReturn = false
    var style: Style = .normal
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var scheme

    init(modifiers: String, key: String, isReturn: Bool = false, style: Style = .normal) {
        self.modifiers = modifiers
        self.key = key
        self.isReturn = isReturn
        self.style = style
    }

    init(_ combo: KeyCombo, style: Style = .normal) {
        self.init(modifiers: combo.modifierSymbols, key: combo.keySymbol, isReturn: combo.isReturn, style: style)
    }

    private var height: CGFloat {
        switch style {
        case .normal, .none, .warning: 19
        case .small: 17
        case .card, .cardHeld, .cardSelected: 18
        }
    }

    private var fontSize: CGFloat {
        switch style {
        case .normal, .none, .warning: 11
        case .small: 10
        case .card, .cardHeld, .cardSelected: 10.5
        }
    }

    var body: some View {
        Group {
            if isReturn {
                HStack(spacing: 1) {
                    if !modifiers.isEmpty { Text(modifiers) }
                    Image(systemName: "return").font(.system(size: fontSize - 1.5, weight: .medium))
                }
            } else {
                Text(verbatim: modifiers + key)
            }
        }
        .font(.system(size: fontSize, weight: .medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, 5)
        .frame(minWidth: 19, minHeight: height, maxHeight: height)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(background))
        .overlay {
            if style != .cardSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(palette.kbLine, lineWidth: 0.5)
            }
        }
        .fixedSize()
    }

    private var foreground: Color {
        switch style {
        case .normal, .small: palette.text2
        case .card: palette.text3
        case .cardHeld: palette.accentInk
        case .cardSelected: .white
        case .none: palette.text3
        case .warning: SettingsPalette.of(scheme).warning
        }
    }

    private var background: Color {
        switch style {
        case .cardHeld: palette.accentSoft
        case .cardSelected: palette.accent
        case .warning: SettingsPalette.of(scheme).warningSoft
        default: palette.kbBg
        }
    }
}

/// 画面上のキーのヒント（キー + 説明）
struct Hint: View {
    let combos: [KeyCombo]
    let label: String
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                ForEach(Array(combos.enumerated()), id: \.offset) { _, combo in KeyChip(combo) }
            }
            Text(label).foregroundStyle(palette.text2)
        }
        .fixedSize()
    }
}

/// コピー元アプリのアイコン。実機はアプリの本物のアイコン、見つからなければ名前の頭文字の札
struct AppIconView: View {
    let bundleID: String?
    let name: String
    let size: CGFloat
    @Environment(\.appIcons) private var icons
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if let tile = icons.tile(bundleID) {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(LinearGradient(colors: [tile.top, tile.bottom], startPoint: .top, endPoint: .bottom))
                    .overlay(
                        Image(systemName: tile.symbol)
                            .font(.system(size: size * 0.55, weight: .semibold))
                            .foregroundStyle(.white))
            } else if let image = icons.image(bundleID) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(palette.fill3)
                    .overlay(
                        Text(String(name.prefix(1)).uppercased())
                            .font(.system(size: size * 0.6, weight: .semibold))
                            .foregroundStyle(palette.text2))
            }
        }
        .frame(width: size, height: size)
    }
}

/// アプリのアイコンの出し方。実機は NSWorkspace のアイコン。オフスクリーン描画の検証では、
/// 試作と同じ色の札（`tiles`）にして見比べやすくし、手元に入っているアプリが写らないようにする。
/// SwiftUI の描画（メインスレッド）からだけ使う
final class AppIconProvider: @unchecked Sendable {
    struct Tile {
        let top: Color
        let bottom: Color
        let symbol: String
    }

    static let shared = AppIconProvider()

    var tiles: [String: Tile]?
    private var cache: [String: NSImage] = [:]
    private var missing: Set<String> = []

    init(tiles: [String: Tile]? = nil) {
        self.tiles = tiles
    }

    func tile(_ bundleID: String?) -> Tile? {
        guard let tiles else { return nil }
        return bundleID.flatMap { tiles[$0] }
    }

    func image(_ bundleID: String?) -> NSImage? {
        guard tiles == nil, let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        if missing.contains(bundleID) { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            missing.insert(bundleID)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}

private struct AppIconsKey: EnvironmentKey {
    static let defaultValue = AppIconProvider.shared
}

extension EnvironmentValues {
    var appIcons: AppIconProvider {
        get { self[AppIconsKey.self] }
        set { self[AppIconsKey.self] = newValue }
    }
}

/// 空の状態（履歴なし・検索で 0 件・ピン留めなし・絞り込みで 0 件）。試作の Mk.emptyHTML の compact
struct EmptyStateView: View {
    let model: HistoryPanelModel
    @Environment(\.palette) private var palette

    var body: some View {
        let content = Self.content(for: model)
        VStack(spacing: 6) {
            Image(systemName: content.symbol)
                .font(.system(size: 22))
                .foregroundStyle(palette.text3)
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.fill1))
                .padding(.bottom, 6)
            Text(content.title)
                .css(CSS.emptyTitle)
                .foregroundStyle(palette.text)
                .multilineTextAlignment(.center)
            Text(content.message)
                .css(CSS.emptyText)
                .foregroundStyle(palette.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
                .fixedSize(horizontal: false, vertical: true)
            if let (action, label) = content.hint, let combo = model.keymap.primary(action) {
                HStack(spacing: 5) {
                    KeyChip(combo)
                    Text(label)
                }
                .font(.system(size: 12))
                .foregroundStyle(palette.text2)
                .padding(.top, 8)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    struct Content {
        var symbol: String
        var title: String
        var message: String
        var hint: (KeyAction, String)?
    }

    static func content(for model: HistoryPanelModel) -> Content {
        if model.showsSnippets {
            if !model.query.isEmpty, !model.allSnippets.isEmpty {
                return Content(
                    symbol: "magnifyingglass", title: "「\(model.query)」は見つかりませんでした",
                    message: "名前・略語・本文から探します。ローマ字・ひらがな・カタカナ・半角でも探せます。", hint: (.close, "検索を消す"))
            }
            // 試作に無い状態（試作の定型文は 6 件の見本で、0 件にならない）
            return Content(
                symbol: PanelSymbols.snippet, title: "定型文はまだありません",
                message: "よく使う文を登録しておくと、ここから貼れます。{{日付}} などの差し込みは、貼るときに置き換わります。",
                hint: (.editSnippet, "新しい定型文"))
        }
        if model.allItems.isEmpty {
            return Content(
                symbol: "tray", title: "まだ履歴がありません",
                message: "キー操作でも、コピーボタンでも、コピーしたものはここにたまります。画像・コード・ファイルも残ります。",
                hint: (.snippets, "定型文を見る"))
        }
        if !model.query.isEmpty {
            return Content(
                symbol: "magnifyingglass", title: "「\(model.query)」は見つかりませんでした",
                message: "ローマ字・ひらがな・カタカナ・半角でも探せます。絞り込みを外すと見つかるかもしれません。",
                hint: (.close, "検索を消す"))
        }
        if model.pinnedOnly {
            return Content(
                symbol: "tray", title: "ピン留めはまだありません",
                message: "よく使う項目を選んで固定すると、古くなっても消えずにここに残ります。", hint: (.togglePin, "選んだ項目をピン留め"))
        }
        return Content(
            symbol: "tray", title: "条件に合う項目はありません", message: "種類・コピー方法・アプリの絞り込みを変えてみてください。",
            hint: (.kindNext, "種類を切り替え"))
    }
}

/// 0 件で貼ろうとしたときの揺れ（試作の shake）
struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(animatableData * .pi * 4), y: 0))
    }
}
