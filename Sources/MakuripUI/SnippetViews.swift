import AppKit
import MakuripCore
import SwiftUI

/// 定型文の差し込みの札（試作の .ph: 角丸・字は 0.9em・行の高さ 1.5・定型文の色の文字と 15% の地）。
///
/// SwiftUI の Text の中に角丸の札は描けないので、札を画像にして `Text(Image)` で文の中に置く（折り返し・行数の制限が効く）。
/// 画像は描くときに作る（`NSImage` の描画ハンドラ）ので、画面の倍率に合う
@MainActor
enum SnippetChip {
    private static var cache: [String: (image: NSImage, baseline: CGFloat)] = [:]

    /// 札の画像と、文の基準線から札の下端までの距離（`baselineOffset` に負で渡す）
    static func image(_ placeholder: SnippetPlaceholder, fontSize: CGFloat, palette: PanelPalette) -> (
        image: NSImage, baseline: CGFloat
    ) {
        let key = "\(placeholder.rawValue)-\(fontSize)-\(palette.isDark)"
        if let cached = cache[key] { return cached }
        let size = (fontSize * 0.9 * 100).rounded() / 100
        let font = NSFont.systemFont(ofSize: size)
        let ink = NSColor(palette.snippet)
        let text = NSAttributedString(string: placeholder.rawValue, attributes: [.font: font, .foregroundColor: ink])
        let textSize = text.size()
        let height = (size * 1.5).rounded(.up)
        // 左右の margin 1px と padding 6px
        let width = ceil(textSize.width) + 12 + 2
        let top = (height - textSize.height) / 2
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            let chip = NSBezierPath(
                roundedRect: NSRect(x: 1, y: 0, width: width - 2, height: height), xRadius: 5, yRadius: 5)
            ink.withAlphaComponent(0.15).setFill()
            chip.fill()
            text.draw(at: NSPoint(x: 7, y: top))
            return true
        }
        let baseline = height - (top + font.ascender)
        cache[key] = (image, baseline)
        return (image, baseline)
    }
}

/// 定型文の本文（差し込みは札にする。検索語には印）
struct SnippetBodyText: View {
    /// 定型文の本文（`body` は View の名前なので `source` と呼ぶ）
    let source: String
    let query: SearchQuery
    let fontSize: CGFloat
    @Environment(\.palette) private var palette

    init(_ source: String, query: SearchQuery, fontSize: CGFloat) {
        self.source = source
        self.query = query
        self.fontSize = fontSize
    }

    var body: some View {
        Self.text(source, query: query, fontSize: fontSize, palette: palette)
    }

    /// 文字と札をつないだ 1 つの Text（`+` は macOS 26 で非推奨なので文字列の差し込みでつなぐ）
    static func text(_ body: String, query: SearchQuery, fontSize: CGFloat, palette: PanelPalette) -> Text {
        var result = Text(verbatim: "")
        for segment in SnippetTemplate.segments(body) {
            let piece: Text
            switch segment {
            case .text(let literal):
                piece = Text(Highlight.attributed(literal, query: query, mark: palette.mark))
            case .placeholder(let kind):
                let chip = SnippetChip.image(kind, fontSize: fontSize, palette: palette)
                piece = Text(Image(nsImage: chip.image)).baselineOffset(-chip.baseline)
            }
            result = Text("\(result)\(piece)")
        }
        return result
    }
}

/// 一覧の定型文のカード（試作の .card に .cb-snippet。名前・本文 3 行・「定型文 · 略語」・番号）
struct SnippetCardView: View {
    let snippet: Snippet
    let index: Int
    let isSelected: Bool
    let query: SearchQuery
    let quickHeld: Bool
    let quickCombo: KeyCombo?
    @Environment(\.palette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Highlight.attributed(snippet.name, query: query, mark: palette.mark))
                    .lineLimit(1)
                    .css(CSS.snippetName)
                    .foregroundStyle(palette.text)
                SnippetBodyText(snippet.body, query: query, fontSize: CSS.snippetBody.size)
                    .lineLimit(3)
                    .css(CSS.snippetBody)
                    .foregroundStyle(palette.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                SnippetMetaLine(snippet: snippet)
                Spacer(minLength: 6)
                if index < 9, let quickCombo {
                    KeyChip(
                        modifiers: quickCombo.modifierSymbols, key: String(index + 1),
                        style: isSelected ? .cardSelected : (quickHeld ? .cardHeld : .card))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(palette.text2)
            .frame(height: 18)
        }
        .padding(EdgeInsets(top: 9, leading: 11, bottom: 7, trailing: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            OuterShadow(
                shape: shape, color: isSelected ? palette.accent.opacity(0.45) : .black.opacity(0.05),
                radius: isSelected ? 7 : 1, y: isSelected ? 4 : 1)
            shape.fill(palette.card)
        }
        .overlay {
            let width: CGFloat = isSelected ? 2 : 0.5
            shape.inset(by: -width / 2).stroke(isSelected ? palette.accent : palette.sep, lineWidth: width)
        }
        .contentShape(shape)
    }
}

/// カードの下の行（試作の Mk.metaHTML の定型文: 「定型文 · ;略語」）
struct SnippetMetaLine: View {
    let snippet: Snippet
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            Text("定型文")
                .fontWeight(.semibold)
                .foregroundStyle(palette.snippet)
                .fixedSize()
            if !snippet.abbreviation.isEmpty {
                MetaDot()
                Text(snippet.abbreviation)
                    .font(CSSText.mono(10.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .lineLimit(1)
    }
}

/// ⌘Y の定型文（試作の pk-head・.pv-snippet・.pv-note・details）
struct SnippetPeekContent: View {
    let snippet: Snippet
    let model: HistoryPanelModel
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SnippetBadge()
                Text(DisplayText.snippetInfo(snippet))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.text2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let combo = model.keymap.primary(.preview) {
                    HStack(spacing: 5) {
                        KeyChip(combo)
                        Text("閉じる")
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.text2)
                    .onTapGesture { model.setPreviewOpen(false) }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    SnippetBodyText(snippet.body, query: model.searchQuery, fontSize: CSS.previewSnippet.size)
                        .css(CSS.previewSnippet)
                        .foregroundStyle(palette.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.well))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(
                                palette.wellLine, lineWidth: 0.5))
                    note
                }
                .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.well))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.wellLine, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 12)
            details
                .padding(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
        }
    }

    /// 置き換わることの説明（試作の文）と、編集のキー（試作に無い。定型文の窓は #7 で足した）
    private var note: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: PanelSymbols.snippet).font(.system(size: 11))
            VStack(alignment: .leading, spacing: 4) {
                Text(DisplayText.snippetNote(now: model.now, format: model.snippetDateFormat))
                    .fixedSize(horizontal: false, vertical: true)
                if let combo = model.keymap.primary(.editSnippet) {
                    HStack(spacing: 5) {
                        KeyChip(combo)
                        Text("で編集します。")
                    }
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(palette.text2)
    }

    private var details: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                cell("略語") {
                    Text(snippet.abbreviation.isEmpty ? "なし" : snippet.abbreviation)
                        .font(CSSText.mono(12))
                        .foregroundStyle(snippet.abbreviation.isEmpty ? palette.text3 : palette.text)
                        .lineLimit(1)
                }
                cell("種類") { Text("定型文（履歴とは別に保存）").lineLimit(1) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cell<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).css(CSS.detailTitle).foregroundStyle(palette.text3)
            HStack(spacing: 6) { content() }.css(CSS.detailValue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 種類の札の定型文版（試作の .kbadge[data-kind=snippet]）
struct SnippetBadge: View {
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: PanelSymbols.snippet).font(.system(size: 10.5))
            Text("定型文")
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(palette.snippet)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.snippet.opacity(0.14)))
    }
}
