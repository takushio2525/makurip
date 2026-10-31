import AppKit
import MakuripCore
import SwiftUI

/// コードとコマンドを色付きの文字列にする。配色は試作（base.css の .s-*）と同じで、キーワードだけ太くする（試作の font-weight: 600）。
///
/// - 一覧のカード（コードは 5 行・コマンドは 3 行）と ⌘Y のコマンド: SwiftUI の Text に渡す AttributedString。
///   区間を 1 つずつ足すと遅い（3000 区間で 55 ms）ので、NSMutableAttributedString に SwiftUI の属性の鍵で色を付けてから
///   一度に変換する（同じ量で 12 ms）
/// - ⌘Y のコード: NSTextView に渡す NSAttributedString（`appKit`）。SwiftUI の Text は区間が多いと組むのが極端に遅いため
enum CodeStyler {
    struct Style: Sendable {
        let syntax: [SyntaxTokenKind: Color]
        let prompt: Color
        let mark: Color
        let keywordFont: Font
        let size: CGFloat

        init(palette: PanelPalette, size: CGFloat) {
            syntax = palette.syntax
            prompt = palette.prompt
            mark = palette.mark
            keywordFont = Font(NSFont.monospacedSystemFont(ofSize: size, weight: .semibold))
            self.size = size
        }
    }

    static let foregroundKey = NSAttributedString.Key(AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.name)
    static let backgroundKey = NSAttributedString.Key(AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.name)
    static let fontKey = NSAttributedString.Key(AttributeScopes.SwiftUIAttributes.FontAttribute.name)

    /// コードを行ごとに（一覧のカードは 1 行ずつ折り返さずに出すため）。最大 `maxLines` 行
    static func codeLines(_ text: String, language: CodeLanguage?, style: Style, query: SearchQuery, maxLines: Int)
        -> [AttributedString]
    {
        let lines = text.split(separator: "\n", maxSplits: maxLines, omittingEmptySubsequences: false).prefix(maxLines)
        let head = lines.joined(separator: "\n")
        let styled = build(
            head, tokens: SyntaxHighlighter.tokens(in: head, language: language), style: style, query: query)
        var result: [AttributedString] = []
        var location = 0
        for line in lines {
            let length = line.utf16.count
            result.append(convert(styled.attributedSubstring(from: NSRange(location: location, length: length))))
            location += length + 1
        }
        return result
    }

    /// コマンド: 行頭のプロンプト（貼るときに外すもの）を薄くし、残りをシェルとして色付けする。
    /// プロンプトのある文字列では、コマンドの行（プロンプトの行と続きの行）だけに色を付け、出力の行は色なしにする
    static func command(_ text: String, style: Style, query: SearchQuery) -> AttributedString {
        let analysis = ShellPrompt.analyze(text)
        let prompts = analysis.promptRanges
        // プロンプトを同じ長さの空白に置き換えてから色付けする（直後の語をコマンドの位置として見るため）
        let masked = NSMutableString(string: text)
        for range in prompts {
            masked.replaceCharacters(in: range, with: String(repeating: " ", count: range.length))
        }
        var tokens = SyntaxHighlighter.tokens(in: masked as String, language: .shell)
        if analysis.hasPrompt {
            let commandLines = analysis.commandLineRanges
            tokens = tokens.filter { token in commandLines.contains { NSLocationInRange(token.location, $0) } }
        }
        let styled = build(text, tokens: tokens, style: style, query: query)
        for range in prompts {
            styled.addAttribute(foregroundKey, value: style.prompt, range: range)
        }
        return convert(styled)
    }

    static func build(_ text: String, tokens: [SyntaxToken], style: Style, query: SearchQuery)
        -> NSMutableAttributedString
    {
        let result = NSMutableAttributedString(string: text)
        let length = result.length
        for token in tokens where token.location + token.length <= length {
            if let color = style.syntax[token.kind] {
                result.addAttribute(foregroundKey, value: color, range: token.range)
            }
            if token.kind == .keyword {
                result.addAttribute(fontKey, value: style.keywordFont, range: token.range)
            }
        }
        if !query.isEmpty {
            for range in query.highlightRanges(in: text) {
                result.addAttribute(backgroundKey, value: style.mark, range: NSRange(range, in: text))
            }
        }
        return result
    }

    // MARK: AppKit（⌘Y のプレビューの NSTextView 用）

    /// NSTextView に渡す書体・色・行の高さ。CSS の line-height と同じく、行の高さを固定して字を上下の真ん中に置く
    struct AppKitStyle {
        let font: NSFont
        let keywordFont: NSFont
        let lineHeight: CGFloat
        let baselineOffset: CGFloat
        let text: NSColor
        let mark: NSColor
        let syntax: [SyntaxTokenKind: NSColor]

        @MainActor
        init(palette: PanelPalette, css: CSSText) {
            font = NSFont.monospacedSystemFont(ofSize: css.size, weight: .regular)
            keywordFont = NSFont.monospacedSystemFont(ofSize: css.size, weight: .semibold)
            lineHeight = css.lineHeight
            // TextKit は固定した行の高さの余りを字の上に置くので、半分だけ字を持ち上げて CSS の half-leading と同じにする
            baselineOffset = css.extra / 2
            text = NSColor(palette.text)
            mark = NSColor(palette.mark)
            syntax = palette.syntax.mapValues { NSColor($0) }
        }

        func attributes(color: NSColor, alignment: NSTextAlignment = .natural) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
            paragraph.alignment = alignment
            return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph, .baselineOffset: baselineOffset]
        }
    }

    static func appKit(_ text: String, tokens: [SyntaxToken], style: AppKitStyle, query: SearchQuery)
        -> NSAttributedString
    {
        let result = NSMutableAttributedString(string: text, attributes: style.attributes(color: style.text))
        let length = result.length
        for token in tokens where token.location + token.length <= length {
            if let color = style.syntax[token.kind] {
                result.addAttribute(.foregroundColor, value: color, range: token.range)
            }
            if token.kind == .keyword {
                result.addAttribute(.font, value: style.keywordFont, range: token.range)
            }
        }
        if !query.isEmpty {
            for range in query.highlightRanges(in: text) {
                result.addAttribute(.backgroundColor, value: style.mark, range: NSRange(range, in: text))
            }
        }
        return result
    }

    static func convert(_ string: NSAttributedString) -> AttributedString {
        (try? AttributedString(string, including: \.swiftUI)) ?? AttributedString(string.string)
    }
}
