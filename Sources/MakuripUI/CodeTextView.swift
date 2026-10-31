import AppKit
import MakuripCore
import SwiftUI

/// ⌘Y のプレビューのコード本文（TextKit の NSTextView）。試作の .pv-code: 行番号は左に固定し、本文は折り返さずに横へ送る。
///
/// SwiftUI の Text は色の区間が多いと組むのが極端に遅い（色付きの 600 行で 2.5 秒）ので、プレビューは TextKit で描く
/// （同じものが 44 ms。見えている所だけを組む）。行をまたいで選べる。行の高さは CSS の line-height と同じに固定する
struct CodeTextView: NSViewRepresentable {
    /// 中身が変わったかを見る鍵（項目の ID と内容のハッシュ）
    let contentKey: String
    let text: String
    /// 色付けの区間。まだなければ nil（色なしで出し、届いたら塗り直す）
    let tokens: [SyntaxToken]?
    let query: SearchQuery
    let palette: PanelPalette
    var css = CSS.previewCode
    /// 試作の .pk-body の上下の padding（中身と一緒に送られる）
    var verticalInset: CGFloat = 16

    final class Coordinator {
        var appliedKey: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        // 試作の .gutter の margin-right（行番号の線から本文まで 14pt）と、上下の padding
        textView.textContainerInset = NSSize(width: 14, height: verticalInset)
        textView.layoutManager?.allowsNonContiguousLayout = true
        scrollView.documentView = textView

        let ruler = LineNumberRuler(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let key = "\(contentKey)-\(tokens == nil ? "plain" : "styled")-\(palette.isDark)-\(query.terms)"
        guard context.coordinator.appliedKey != key,
            let textView = scrollView.documentView as? NSTextView,
            let ruler = scrollView.verticalRulerView as? LineNumberRuler
        else { return }
        context.coordinator.appliedKey = key
        let style = CodeStyler.AppKitStyle(palette: palette, css: css)
        textView.textStorage?.setAttributedString(
            CodeStyler.appKit(text, tokens: tokens ?? [], style: style, query: query))
        textView.selectedTextAttributes = [.backgroundColor: NSColor(palette.accentSoft)]
        ruler.configure(
            lineCount: DisplayText.lineCount(text), style: style, numberColor: NSColor(palette.text3),
            separatorColor: NSColor(palette.sep), topInset: verticalInset)
    }
}

/// 行番号（試作の .gutter: 右寄せ・薄い字・右に 14pt あけて 0.5pt の線）。本文と同じ行の高さで、縦にだけ一緒に動く
final class LineNumberRuler: NSRulerView {
    private var lineCount = 1
    private var style: CodeStyler.AppKitStyle?
    private var numberColor = NSColor.tertiaryLabelColor
    private var separatorColor = NSColor.separatorColor
    private var topInset: CGFloat = 0
    /// 試作の .gutter の padding-right
    static let padding: CGFloat = 14

    init(scrollView: NSScrollView, textView: NSTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) は使わない")
    }

    override var isFlipped: Bool { true }

    func configure(
        lineCount: Int, style: CodeStyler.AppKitStyle, numberColor: NSColor, separatorColor: NSColor,
        topInset: CGFloat
    ) {
        self.lineCount = max(1, lineCount)
        self.style = style
        self.numberColor = numberColor
        self.separatorColor = separatorColor
        self.topInset = topInset
        let digits = String(self.lineCount).count
        let width = ("0" as NSString).size(withAttributes: [.font: style.font]).width * CGFloat(digits)
        ruleThickness = ceil(width) + Self.padding + 0.5
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let style, let textView = clientView as? NSTextView, let scrollView else { return }
        let visible = scrollView.contentView.bounds
        let lineHeight = style.lineHeight
        let first = max(0, Int(floor((visible.minY - topInset) / lineHeight)))
        let last = min(lineCount - 1, Int(ceil((visible.maxY - topInset) / lineHeight)))
        let numberWidth = ruleThickness - Self.padding - 0.5
        if first <= last {
            let attributes = style.attributes(color: numberColor, alignment: .right)
            for index in first...last {
                let top = convert(NSPoint(x: 0, y: topInset + CGFloat(index) * lineHeight), from: textView).y
                NSAttributedString(string: String(index + 1), attributes: attributes)
                    .draw(in: NSRect(x: 0, y: top, width: numberWidth, height: lineHeight))
            }
        }
        // 線は行のある高さだけ（試作は行番号の列の右の枠線）
        let top = convert(NSPoint(x: 0, y: topInset), from: textView).y
        separatorColor.setFill()
        NSRect(x: ruleThickness - 0.5, y: top, width: 0.5, height: CGFloat(lineCount) * lineHeight).fill()
    }
}
