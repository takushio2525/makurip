import AppKit
import ImageIO
import MakuripCore
import SwiftUI

/// 画像の縮小版（一覧のサムネイル・プレビュー用）
struct ImageThumb: @unchecked Sendable {
    let image: CGImage
    /// 元の画像の画素数
    let pixelSize: CGSize
    /// PNG・JPEG など
    let format: String
    /// 元の型のバイト数
    let byteCount: Int
}

struct FileEntry: Hashable {
    let name: String
    /// 表示用のパス（ホームは ~ に縮める）
    let displayPath: String
    let byteCount: Int?
}

struct ColorInfo: Hashable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    var rgb: [Int] { [red, green, blue].map { Int(($0 * 255).rounded()) } }
    var hex: String { "#" + rgb.map { String(format: "%02X", $0) }.joined() }

    /// 色相（度）・彩度・明度（%）。試作の rgbToHsl と同じ
    var hsl: [Int] {
        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let lightness = (maxValue + minValue) / 2
        var hue = 0.0
        var saturation = 0.0
        if maxValue != minValue {
            let d = maxValue - minValue
            saturation = lightness > 0.5 ? d / (2 - maxValue - minValue) : d / (maxValue + minValue)
            if maxValue == red {
                hue = (green - blue) / d + (green < blue ? 6 : 0)
            } else if maxValue == green {
                hue = (blue - red) / d + 2
            } else {
                hue = (red - green) / d + 4
            }
            hue *= 60
        }
        return [Int(hue.rounded()), Int((saturation * 100).rounded()), Int((lightness * 100).rounded())]
    }

    /// `#RRGGBB`・`#RGB`・`rgb(r, g, b)`・`hsl(h, s%, l%)` の 1 語を読む（取り込みの判定 TextHeuristics と同じ範囲）
    static func parse(_ text: String) -> ColorInfo? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") {
            var digits = String(value.dropFirst())
            if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard digits.count == 6 || digits.count == 8, let number = UInt32(digits.prefix(6), radix: 16) else {
                return nil
            }
            return ColorInfo(
                red: Double((number >> 16) & 0xFF) / 255, green: Double((number >> 8) & 0xFF) / 255,
                blue: Double(number & 0xFF) / 255)
        }
        let numbers = value.split { !"0123456789.".contains($0) }.compactMap { Double($0) }
        if value.hasPrefix("rgb"), numbers.count >= 3 {
            return ColorInfo(red: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255)
        }
        if value.hasPrefix("hsl"), numbers.count >= 3 {
            let (h, s, l) = (numbers[0] / 360, numbers[1] / 100, numbers[2] / 100)
            func channel(_ t: Double) -> Double {
                var t = t
                if t < 0 { t += 1 }
                if t > 1 { t -= 1 }
                let q = l < 0.5 ? l * (1 + s) : l + s - l * s
                let p = 2 * l - q
                if t < 1 / 6 { return p + (q - p) * 6 * t }
                if t < 1 / 2 { return q }
                if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
                return p
            }
            return ColorInfo(red: channel(h + 1 / 3), green: channel(h), blue: channel(h - 1 / 3))
        }
        return nil
    }
}

/// ⌘Y のプレビューに出す中身（選んだ 1 件だけ読む）
struct ClipDetail {
    var fullText: String?
    /// 長すぎて途中で切った
    var textTruncated = false
    var richText: AttributedString?
    var image: ImageThumb?
    var files: [FileEntry] = []
    var color: ColorInfo?
    var urlTitle: String?
    /// コードの言語（判定できなければ nil）
    var language: CodeLanguage?
    /// コマンドの、貼るときに外すプロンプトの数（全文で数える）
    var promptCount = 0
    /// 途中で切ったときの、全文の行数と文字数（見出しの「603 行」が切った後の数にならないように）
    var totalLineCount: Int?
    var totalCharacterCount: Int?
}

/// 履歴の中身を、表示する分だけ遅れて読む。読んだ中身は UI の中だけで使い、ログ等に出さない。
///
/// 一覧のカードは見えたものだけが `.task` で読む（数千件でも開く速さが変わらないように）。
/// 画像の縮小（`CGImageSourceCreateThumbnailAtIndex`）はメインスレッドの外で行う。
@MainActor
final class ClipContentLoader {
    weak var actions: HistoryActions?
    private let thumbnails = NSCache<NSString, ThumbBox>()
    private var extras: [String: CardExtras] = [:]
    private var languages: [String: CodeLanguage?] = [:]
    private var cardCode: [String: [AttributedString]] = [:]
    private var cardCommands: [String: AttributedString] = [:]
    private var previewCommands: [String: AttributedString] = [:]
    private var previewTokens: [String: [SyntaxToken]] = [:]

    /// 一覧のサムネイルの長辺（画素）。カードは幅 350pt・高さ 96pt なので 2 倍の画面で足りる大きさ
    static let cardPixelSize: CGFloat = 720
    /// ⌘Y のプレビューの長辺（画素）
    static let previewPixelSize: CGFloat = 1400
    /// プレビューに出す文字の上限（それより長い文章は途中で切る。SwiftUI の Text が重くならないように）
    static let previewCharacterLimit = 20_000

    static let imageTypePreference: [String] = [
        PasteboardTypes.png, PasteboardTypes.jpeg, PasteboardTypes.heic, PasteboardTypes.heif, PasteboardTypes.tiff,
        PasteboardTypes.gif, PasteboardTypes.webp, PasteboardTypes.bmp, PasteboardTypes.pdf,
    ]

    init(actions: HistoryActions?) {
        self.actions = actions
        thumbnails.countLimit = 300
    }

    /// 項目の内容が変わったら（同じ ID でも中身のハッシュで見分ける）別のキャッシュにする
    private static func key(_ item: ClipItem, _ size: CGFloat) -> String {
        "\(item.id.uuidString)-\(item.contentHash)-\(Int(size))"
    }

    func cachedThumbnail(for item: ClipItem, size: CGFloat = cardPixelSize) -> ImageThumb? {
        thumbnails.object(forKey: Self.key(item, size) as NSString)?.thumb
    }

    /// 画像の縮小版。データはメインで読み（DB の中か blobs/ のファイル）、縮小は別のスレッドで行う
    func thumbnail(for item: ClipItem, size: CGFloat = cardPixelSize) async -> ImageThumb? {
        if let cached = cachedThumbnail(for: item, size: size) { return cached }
        guard let source = imageSource(for: item) else { return nil }
        let thumb = await Task.detached(priority: .userInitiated) {
            Self.decode(source.data, type: source.type, maxPixel: size)
        }.value
        if let thumb { thumbnails.setObject(ThumbBox(thumb), forKey: Self.key(item, size) as NSString) }
        return thumb
    }

    /// 同じことをその場で行う（オフスクリーン描画の検証で、描く前に読み終えておくため）
    func loadThumbnailNow(for item: ClipItem, size: CGFloat = cardPixelSize) -> ImageThumb? {
        if let cached = cachedThumbnail(for: item, size: size) { return cached }
        guard let source = imageSource(for: item),
            let thumb = Self.decode(source.data, type: source.type, maxPixel: size)
        else { return nil }
        thumbnails.setObject(ThumbBox(thumb), forKey: Self.key(item, size) as NSString)
        return thumb
    }

    private func imageSource(for item: ClipItem) -> (data: Data, type: String)? {
        guard let actions else { return nil }
        let infos = actions.representationInfos(itemID: item.id)
        for type in Self.imageTypePreference {
            if let info = infos.first(where: { $0.type == type }),
                let data = actions.representationData(itemID: item.id, itemIndex: info.itemIndex, type: type)
            {
                return (data, type)
            }
        }
        return nil
    }

    nonisolated static func decode(_ data: Data, type: String, maxPixel: CGFloat) -> ImageThumb? {
        let format = formatName(type)
        if type == PasteboardTypes.pdf {
            return decodePDF(data, maxPixel: maxPixel)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        var height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if orientation >= 5 { swap(&width, &height) }  // 90 度回転の向き
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if width == 0 || height == 0 { (width, height) = (Double(image.width), Double(image.height)) }
        return ImageThumb(
            image: image, pixelSize: CGSize(width: width, height: height), format: format, byteCount: data.count)
    }

    nonisolated static func decodePDF(_ data: Data, maxPixel: CGFloat) -> ImageThumb? {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
            let page = document.page(at: 1)
        else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(1, maxPixel / max(box.width, box.height)) * 2
        let width = Int(box.width * scale)
        let height = Int(box.height * scale)
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }
        return ImageThumb(image: image, pixelSize: box.size, format: "PDF", byteCount: data.count)
    }

    nonisolated static func formatName(_ type: String) -> String {
        switch type {
        case PasteboardTypes.png: "PNG"
        case PasteboardTypes.jpeg: "JPEG"
        case PasteboardTypes.heic, PasteboardTypes.heif: "HEIC"
        case PasteboardTypes.tiff: "TIFF"
        case PasteboardTypes.gif: "GIF"
        case PasteboardTypes.webp: "WebP"
        case PasteboardTypes.bmp: "BMP"
        case PasteboardTypes.pdf: "PDF"
        default: type
        }
    }

    // MARK: カードの付随情報（URL の題名・色・リッチテキスト・ファイル）

    struct CardExtras {
        var urlTitle: String?
        var color: ColorInfo?
        var richText: AttributedString?
        var files: [FileEntry] = []
    }

    /// カードに出す小さい付随情報。種類ごとに必要なものだけ読む（小さい型だけなのでその場で読む）
    func cardExtras(for item: ClipItem) -> CardExtras {
        let key = "\(item.id.uuidString)-\(item.contentHash)"
        if let cached = extras[key] { return cached }
        var result = CardExtras()
        switch item.kind {
        case .url:
            result.urlTitle = string(item, type: "public.url-name")
        case .color:
            result.color = color(of: item)
        case .richText:
            result.richText = richText(of: item, baseSize: 13, inline: true)
        case .file:
            result.files = files(of: item, limit: 4)
        default:
            break
        }
        extras[key] = result
        if extras.count > 600 { extras.removeAll(keepingCapacity: true) }
        return result
    }

    /// ⌘Y のプレビューの中身（選んだ 1 件）
    func detail(for item: ClipItem) -> ClipDetail {
        var detail = ClipDetail()
        if let text = string(item, type: PasteboardTypes.utf8PlainText) ?? item.previewText {
            if text.count > Self.previewCharacterLimit {
                detail.fullText = String(text.prefix(Self.previewCharacterLimit))
                detail.textTruncated = true
                (detail.totalLineCount, detail.totalCharacterCount) = totalCounts(item, text: text)
            } else {
                detail.fullText = text
            }
        }
        switch item.kind {
        case .richText:
            detail.richText = richText(of: item, baseSize: 14.5, inline: false)
        case .image:
            detail.image = cachedThumbnail(for: item, size: Self.previewPixelSize) ?? cachedThumbnail(for: item)
        case .file:
            detail.files = files(of: item, limit: 200)
        case .color:
            detail.color = color(of: item)
        case .url:
            detail.urlTitle = string(item, type: "public.url-name")
        case .code:
            detail.language = language(for: item)
        case .command:
            detail.promptCount = ShellPrompt.analyze(detail.fullText ?? "").promptRanges.count
        default:
            break
        }
        return detail
    }

    private var counts: [String: (lines: Int, characters: Int)] = [:]

    /// 長い文字列の行数と文字数（全文を数えるのは重いので 1 回だけ）
    private func totalCounts(_ item: ClipItem, text: String) -> (Int, Int) {
        let key = Self.contentKey(item)
        if let cached = counts[key] { return (cached.lines, cached.characters) }
        let lines = DisplayText.lineCount(text)
        let characters = text.count
        if counts.count > 100 { counts.removeAll(keepingCapacity: true) }
        counts[key] = (lines, characters)
        return (lines, characters)
    }

    // MARK: コードとコマンドの色付け

    /// その場で色付けする長さの上限（UTF-16）。これより長いプレビューは裏で作り、できるまでは色なしで出す
    static let syncStyleLimit = 8_000
    /// 一覧のカードに出すコードの行数（試作の .cb-code は 5 行で切る）
    static let cardCodeLines = 5

    private static func contentKey(_ item: ClipItem) -> String {
        "\(item.id.uuidString)-\(item.contentHash)"
    }

    /// コードの言語。一覧の平文（先頭 1000 文字）から 1 回だけ判定し、カードとプレビューで同じものを使う。コマンドはシェル
    func language(for item: ClipItem) -> CodeLanguage? {
        switch item.kind {
        case .command: return .shell
        case .code: break
        default: return nil
        }
        let key = Self.contentKey(item)
        if let cached = languages[key] { return cached }
        let language = CodeLanguageDetector.detect(item.previewText ?? "")
        languages[key] = .some(language)
        if languages.count > 2000 { languages.removeAll(keepingCapacity: true) }
        return language
    }

    /// カードのコード（先頭 5 行を 1 行ずつ）。検索語がないときはキャッシュする
    func codeCardLines(for item: ClipItem, palette: PanelPalette, query: SearchQuery) -> [AttributedString] {
        let style = CodeStyler.Style(palette: palette, size: CSS.cardMono.size)
        let make = {
            CodeStyler.codeLines(
                DisplayText.codeText(item.previewText ?? ""), language: self.language(for: item), style: style,
                query: query, maxLines: Self.cardCodeLines)
        }
        guard query.isEmpty else { return make() }
        let key = Self.contentKey(item) + (palette.isDark ? "-dark" : "-light")
        if let cached = cardCode[key] { return cached }
        let lines = make()
        cardCode[key] = lines
        if cardCode.count > 600 { cardCode.removeAll(keepingCapacity: true) }
        return lines
    }

    /// カードのコマンド（プロンプトを薄く）。検索語がないときはキャッシュする
    func commandCard(for item: ClipItem, palette: PanelPalette, query: SearchQuery) -> AttributedString {
        let style = CodeStyler.Style(palette: palette, size: CSS.cardMono.size)
        let text = DisplayText.codeText(item.previewText ?? "")
        guard query.isEmpty else { return CodeStyler.command(text, style: style, query: query) }
        let key = Self.contentKey(item) + (palette.isDark ? "-dark" : "-light")
        if let cached = cardCommands[key] { return cached }
        let styled = CodeStyler.command(text, style: style, query: query)
        cardCommands[key] = styled
        if cardCommands.count > 600 { cardCommands.removeAll(keepingCapacity: true) }
        return styled
    }

    /// プレビューのコマンド（12 行ほどまでなので、その場で色付けしてキャッシュする）
    func commandPreview(for item: ClipItem, text: String, palette: PanelPalette, query: SearchQuery)
        -> AttributedString
    {
        let key = Self.contentKey(item) + "-\(palette.isDark)-\(query.terms)"
        if let cached = previewCommands[key] { return cached }
        let styled = CodeStyler.command(
            text, style: CodeStyler.Style(palette: palette, size: CSS.previewCommand.size), query: query)
        if previewCommands.count >= 24 { previewCommands.removeAll(keepingCapacity: true) }
        previewCommands[key] = styled
        return styled
    }

    private func tokenKey(_ item: ClipItem, text: String) -> String {
        Self.contentKey(item) + "-\(text.utf16.count)"
    }

    /// プレビューのコードの色付けの区間（配色によらないので区間だけを持つ）。キャッシュにあるか、短ければその場で作る。
    /// 長くてまだなければ nil（`codeTokens` を待つ）
    func cachedCodeTokens(for item: ClipItem, text: String) -> [SyntaxToken]? {
        let key = tokenKey(item, text: text)
        if let cached = previewTokens[key] { return cached }
        guard text.utf16.count <= Self.syncStyleLimit else { return nil }
        let tokens = SyntaxHighlighter.tokens(in: text, language: language(for: item))
        storeTokens(tokens, key: key)
        return tokens
    }

    /// 長いコードの色付けの区間を、メインスレッドの外で作る
    func codeTokens(for item: ClipItem, text: String) async -> [SyntaxToken] {
        let key = tokenKey(item, text: text)
        if let cached = previewTokens[key] { return cached }
        let language = language(for: item)
        let tokens = await Task.detached(priority: .userInitiated) {
            SyntaxHighlighter.tokens(in: text, language: language)
        }.value
        storeTokens(tokens, key: key)
        return tokens
    }

    private func storeTokens(_ tokens: [SyntaxToken], key: String) {
        if previewTokens.count >= 24 { previewTokens.removeAll(keepingCapacity: true) }
        previewTokens[key] = tokens
    }

    // MARK: 秘密（本当の中身は、表示のキーを押している間と ⌘Y のプレビューのためだけに読む）

    /// 秘密の項目の中身。`text` は本当の中身、`masked` はそれを伏せ字にしたもの（どちらも先頭 2 万文字まで）
    struct SecretContent {
        var text: String
        var masked: String
        /// 理由（「API キーの形式」）
        var reason: String
        /// 全文の文字数（見出しの「36 文字」）
        var characterCount: Int
        var truncated: Bool
    }

    private var secrets: [String: SecretContent] = [:]

    func secret(for item: ClipItem) -> SecretContent {
        let key = Self.contentKey(item)
        if let cached = secrets[key] { return cached }
        let full = secretSourceText(item) ?? ""
        let (maskedFull, findings) = SecretMask.masked(full)
        let truncated = full.count > Self.previewCharacterLimit
        // 秘密と判定したのに、ここで読んだ文字の中に見つからない（RTF だけにある等）ときは、全体を伏せ字にする
        let masked =
            findings.isEmpty
            ? String(repeating: SecretMask.bullet, count: 16) : String(maskedFull.prefix(Self.previewCharacterLimit))
        let reason = findings.max { $0.kind.confidence < $1.kind.confidence }?.kind.reason ?? "秘密らしき値"
        let content = SecretContent(
            text: String(full.prefix(Self.previewCharacterLimit)), masked: masked, reason: reason,
            characterCount: full.count, truncated: truncated)
        if secrets.count > 50 { secrets.removeAll() }
        secrets[key] = content
        return content
    }

    /// 読んだ秘密の中身を捨てる（一覧・候補窓を閉じたとき）
    func purgeSecrets() {
        secrets.removeAll()
    }

    /// 秘密の項目の本当の中身（平文の型 → リッチテキスト → ファイル名。一覧用の平文は伏せ字なので使わない）
    private func secretSourceText(_ item: ClipItem) -> String? {
        if item.kind == .file {
            let names = files(of: item, limit: 200).map(\.name)
            return names.isEmpty ? nil : names.joined(separator: "\n")
        }
        for type in [PasteboardTypes.utf8PlainText, PasteboardTypes.plainText] {
            if let text = string(item, type: type) { return text }
        }
        for type in [PasteboardTypes.utf16ExternalPlainText, PasteboardTypes.utf16PlainText] {
            if let data = actions?.representationData(itemID: item.id, itemIndex: 0, type: type),
                let text = String(data: data, encoding: .utf16)
            {
                return text
            }
        }
        if let rich = richText(of: item, baseSize: 13, inline: false) { return String(rich.characters) }
        return nil
    }

    private func string(_ item: ClipItem, type: String, itemIndex: Int = 0) -> String? {
        guard let data = actions?.representationData(itemID: item.id, itemIndex: itemIndex, type: type),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    private func color(of item: ClipItem) -> ColorInfo? {
        if let data = actions?.representationData(itemID: item.id, itemIndex: 0, type: PasteboardTypes.color),
            let color = (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data))?
                .usingColorSpace(.sRGB)
        {
            return ColorInfo(
                red: Double(color.redComponent), green: Double(color.greenComponent), blue: Double(color.blueComponent))
        }
        return item.previewText.flatMap(ColorInfo.parse)
    }

    private func files(of item: ClipItem, limit: Int) -> [FileEntry] {
        let count = min(max(item.pasteboardItemCount, 1), limit)
        var entries: [FileEntry] = []
        for index in 0..<count {
            guard
                let data = actions?.representationData(
                    itemID: item.id, itemIndex: index, type: PasteboardTypes.fileURL),
                let text = String(data: data, encoding: .utf8),
                let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.isFileURL
            else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
            entries.append(
                FileEntry(
                    name: url.lastPathComponent, displayPath: (url.path as NSString).abbreviatingWithTildeInPath,
                    byteCount: size))
        }
        if entries.isEmpty, let names = item.previewText {
            entries = names.split(separator: "\n").prefix(limit).map {
                FileEntry(name: String($0), displayPath: "", byteCount: nil)
            }
        }
        return entries
    }

    private func richText(of item: ClipItem, baseSize: CGFloat, inline: Bool) -> AttributedString? {
        let candidates: [(String, NSAttributedString.DocumentType)] = [
            (PasteboardTypes.rtf, .rtf), (PasteboardTypes.rtfd, .rtfd),
        ]
        for (type, documentType) in candidates {
            guard let data = actions?.representationData(itemID: item.id, itemIndex: 0, type: type),
                let source = try? NSAttributedString(
                    data: data, options: [.documentType: documentType], documentAttributes: nil)
            else { continue }
            return RichTextStyler.style(source, baseSize: baseSize, inline: inline)
        }
        return nil
    }
}

private final class ThumbBox {
    let thumb: ImageThumb
    init(_ thumb: ImageThumb) { self.thumb = thumb }
}

/// リッチテキストを一覧の見た目にそろえる。太字・斜体・下線・リンクは残し、文字の大きさと色はそろえる
/// （書き手の色のままだとダークで読めないことがあるため）。大きい文字（見出し）は少し大きく太くする
enum RichTextStyler {
    static func style(_ source: NSAttributedString, baseSize: CGFloat, inline: Bool) -> AttributedString {
        var sizes: [CGFloat] = []
        source.enumerateAttribute(.font, in: NSRange(location: 0, length: source.length)) { value, range, _ in
            if let font = value as? NSFont, range.length > 0 { sizes.append(font.pointSize) }
        }
        let typical = sizes.sorted().dropFirst(sizes.count / 2).first ?? 12
        var result = AttributedString()
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            var text = (source.string as NSString).substring(with: range)
            if inline { text = text.replacingOccurrences(of: "\n", with: "  ") }
            var run = AttributedString(text)
            let font = attributes[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let heading = (font?.pointSize ?? typical) >= typical * 1.2
            var swiftFont = Font.system(size: heading && !inline ? baseSize * 1.17 : baseSize)
            if traits.contains(.bold) || heading { swiftFont = swiftFont.weight(.semibold) }
            if traits.contains(.italic) { swiftFont = swiftFont.italic() }
            run.font = swiftFont
            if attributes[.link] != nil {
                run.underlineStyle = .single
                run.foregroundColor = .accentColor
            } else if let underline = attributes[.underlineStyle] as? Int, underline != 0 {
                run.underlineStyle = .single
            }
            if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { run.strikethroughStyle = .single }
            result += run
        }
        return result
    }
}
