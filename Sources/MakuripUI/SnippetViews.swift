import AppKit
import MakuripCore
import SwiftUI

/// 定型文の差し込みの札（試作の .ph: 角丸 5・字は 0.9em・行の高さ 1.5・左右 6px の余白と 1px の間・定型文の色の文字と 15% の地）。
/// 本文の中に `NSTextAttachment` の画像として置く。画像は描くときに作る（描画ハンドラ）ので、画面の倍率に合う
@MainActor
enum SnippetChip {
    private static var cache: [String: (image: NSImage, descent: CGFloat)] = [:]

    /// 札の画像と、文の基準線から札の下端までの距離（CSS の inline-block と同じく、札の中の字の基準線を文の基準線にそろえる）
    static func image(_ placeholder: SnippetPlaceholder, fontSize: CGFloat, palette: PanelPalette) -> (
        image: NSImage, descent: CGFloat
    ) {
        let key = "\(placeholder.rawValue)-\(fontSize)-\(palette.isDark)"
        if let cached = cache[key] { return cached }
        let size = (fontSize * 0.9 * 100).rounded() / 100
        let font = NSFont.systemFont(ofSize: size)
        let ink = NSColor(palette.snippet)
        let text = NSAttributedString(string: placeholder.rawValue, attributes: [.font: font, .foregroundColor: ink])
        let height = size * 1.5
        let content = font.ascender - font.descender
        // CSS の half-leading: 札の中の字は、行の高さの中で上下に同じだけ空ける
        let baselineFromTop = (height - content) / 2 + font.ascender
        let width = ceil(text.size().width) + 12 + 2
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            let chip = NSBezierPath(
                roundedRect: NSRect(x: 1, y: 0, width: width - 2, height: height), xRadius: 5, yRadius: 5)
            ink.withAlphaComponent(0.15).setFill()
            chip.fill()
            text.draw(
                with: NSRect(x: 7, y: baselineFromTop, width: width, height: height), options: [],
                context: nil)
            return true
        }
        let entry = (image, height - baselineFromTop)
        cache[key] = entry
        return entry
    }
}

/// 定型文の本文を TextKit で組む（差し込みは札・検索語には印）。
///
/// SwiftUI の Text に画像を入れると、基準線より下に出る分だけ行が高くなり、試作（CSS の line-height で行の高さが一定）と
/// ずれるので、行の高さを段落の指定（最小 = 最大）で固定できる TextKit で組む。CSS と同じく、行の余りは字の上下に半分ずつ
enum SnippetBodyLayout {
    @MainActor
    static func attributed(
        _ body: String, query: SearchQuery, css: CSSText, color: Color, palette: PanelPalette
    ) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: css.size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = css.lineHeight
        paragraph.maximumLineHeight = css.lineHeight
        paragraph.lineBreakMode = .byWordWrapping
        let natural = font.ascender - font.descender
        // TextKit は行の余りを字の上に置くので、半分だけ持ち上げて CSS と同じく上下に分ける
        let raise = max(0, css.lineHeight - natural) / 2
        let base: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(color), .paragraphStyle: paragraph, .baselineOffset: raise,
        ]
        let result = NSMutableAttributedString()
        for segment in SnippetTemplate.segments(body) {
            switch segment {
            case .text(let literal):
                let piece = NSMutableAttributedString(string: literal, attributes: base)
                for range in query.highlightRanges(in: literal) {
                    piece.addAttribute(
                        .backgroundColor, value: NSColor(palette.mark), range: NSRange(range, in: literal))
                }
                result.append(piece)
            case .placeholder(let kind):
                let chip = SnippetChip.image(kind, fontSize: css.size, palette: palette)
                let attachment = NSTextAttachment()
                attachment.image = chip.image
                attachment.bounds = CGRect(
                    x: 0, y: -chip.descent, width: chip.image.size.width, height: chip.image.size.height)
                let piece = NSMutableAttributedString(attachment: attachment)
                piece.addAttributes(base, range: NSRange(location: 0, length: piece.length))
                result.append(piece)
            }
        }
        return result
    }
}

/// 定型文の本文（`maxLines` で切り、最後の行の末尾に「…」。0 は切らない）
struct SnippetBodyText: NSViewRepresentable {
    /// 定型文の本文（`body` は View の名前なので `source` と呼ぶ）
    let source: String
    let query: SearchQuery
    let css: CSSText
    let color: Color
    let maxLines: Int
    @Environment(\.palette) private var palette

    init(_ source: String, query: SearchQuery, css: CSSText, color: Color, maxLines: Int = 0) {
        self.source = source
        self.query = query
        self.css = css
        self.color = color
        self.maxLines = maxLines
    }

    func makeNSView(context: Context) -> SnippetTextNSView {
        let view = SnippetTextNSView()
        update(view)
        return view
    }

    func updateNSView(_ view: SnippetTextNSView, context: Context) {
        update(view)
    }

    private func update(_ view: SnippetTextNSView) {
        view.set(
            SnippetBodyLayout.attributed(source, query: query, css: css, color: color, palette: palette),
            maxLines: maxLines)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SnippetTextNSView, context: Context) -> CGSize? {
        let width = proposal.width ?? 330
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}

/// TextKit で組んで描くだけの面（選択・編集はしない）。
///
/// 行数を切るときは CSS の line-clamp と同じにする: 先頭の `maxLines` 行だけを出し、続きがあれば最後の行の末尾に「…」。
/// TextKit の行数の上限だけに任せると、最後の行に続きの文を詰めて出すので（空の行が飛ぶ）、自分で切ってから組む
final class SnippetTextNSView: NSView {
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer(size: CGSize(width: 330, height: CGFloat.greatestFiniteMagnitude))
    private var full = NSAttributedString()
    private var maxLines = 0
    /// いま組んである幅（幅が変わったら切り直す）
    private var laidOutWidth: CGFloat = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    override var isFlipped: Bool { true }

    func set(_ text: NSAttributedString, maxLines: Int) {
        guard !full.isEqual(to: text) || self.maxLines != maxLines else { return }
        full = text
        self.maxLines = maxLines
        laidOutWidth = -1
        needsDisplay = true
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        layOut(width: width)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }

    override func layout() {
        super.layout()
        layOut(width: bounds.width)
    }

    override func draw(_ dirtyRect: NSRect) {
        layOut(width: bounds.width)
        let glyphs = manager.glyphRange(for: container)
        manager.drawBackground(forGlyphRange: glyphs, at: .zero)
        manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }

    private func layOut(width: CGFloat) {
        guard width > 0, width != laidOutWidth else { return }
        laidOutWidth = width
        container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        container.maximumNumberOfLines = 0
        container.lineBreakMode = .byWordWrapping
        storage.setAttributedString(full)
        guard maxLines > 0, let end = endOfLine(maxLines), end < storage.length else { return }
        // 先頭の maxLines 行で切り、その行を終える改行を 1 つだけ除いて「…」を足す（空の行なら「…」だけの行になる。
        // 長くて入らなければ TextKit が末尾を「…」で切る）
        let clipped = NSMutableAttributedString(attributedString: full.attributedSubstring(from: NSRange(0..<end)))
        if clipped.length > 0, (clipped.string as NSString).character(at: clipped.length - 1) == 0x0A {
            clipped.deleteCharacters(in: NSRange(location: clipped.length - 1, length: 1))
        }
        let attributes = full.attributes(at: max(0, min(end, full.length - 1)), effectiveRange: nil)
            .filter { $0.key != .attachment }
        clipped.append(NSAttributedString(string: "…", attributes: attributes))
        container.maximumNumberOfLines = maxLines
        container.lineBreakMode = .byTruncatingTail
        storage.setAttributedString(clipped)
    }

    /// `count` 行目の終わりの文字の位置（行がそれより少なければ nil）
    private func endOfLine(_ count: Int) -> Int? {
        manager.ensureLayout(for: container)
        var lines = 0
        var end: Int?
        let glyphs = manager.glyphRange(for: container)
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, range, stop in
            lines += 1
            if lines == count {
                end = self.manager.characterRange(forGlyphRange: range, actualGlyphRange: nil).upperBound
                stop.pointee = true
            }
        }
        return end
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
                SnippetBodyText(snippet.body, query: query, css: CSS.snippetBody, color: palette.text2, maxLines: 3)
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
                    SnippetBodyText(
                        snippet.body, query: model.searchQuery, css: CSS.previewSnippet, color: palette.text
                    )
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
