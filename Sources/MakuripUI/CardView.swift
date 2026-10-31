import AppKit
import MakuripCore
import SwiftUI

/// 一覧のカード 1 枚（試作の .card。種類ごとの本文と、種類・アプリ・時刻・コピー方法・番号の行）
struct CardView: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    let query: SearchQuery
    let now: Date
    let quickHeld: Bool
    let quickCombo: KeyCombo?
    let loader: ClipContentLoader
    @Environment(\.palette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        VStack(alignment: .leading, spacing: 7) {
            CardBody(item: item, query: query, loader: loader)
            HStack(spacing: 0) {
                MetaLine(item: item, now: now)
                Spacer(minLength: 6)
                if index < 9, let quickCombo {
                    KeyChip(
                        modifiers: quickCombo.modifierSymbols, key: "\(index + 1)",
                        style: isSelected ? .cardSelected : (quickHeld ? .cardHeld : .card))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(palette.text2)
            .frame(height: 18)
        }
        .padding(EdgeInsets(top: 9, leading: 11, bottom: 7, trailing: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(palette.card).shadow(color: .black.opacity(0.05), radius: 1, y: 1))
        .overlay {
            // 試作は枠の外側に線を引く（box-shadow 0 0 0 .5px / 選択中は 2px）
            let width: CGFloat = isSelected ? 2 : 0.5
            shape.inset(by: -width / 2).stroke(isSelected ? palette.accent : palette.sep, lineWidth: width)
        }
        .shadow(color: isSelected ? palette.accent.opacity(0.35) : .clear, radius: 6, y: 4)
        .contentShape(shape)
    }
}

/// カードの本文（種類ごと）
struct CardBody: View {
    let item: ClipItem
    let query: SearchQuery
    let loader: ClipContentLoader
    @Environment(\.palette) private var palette

    var body: some View {
        switch item.kind {
        case .text:
            Text(Highlight.attributed(item.previewText ?? "", query: query, mark: palette.mark))
                .font(.system(size: 13))
                .lineSpacing(2.5)
                .lineLimit(3)
                .foregroundStyle(palette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .richText:
            RichCardBody(item: item, query: query, loader: loader)
        case .image:
            ImageCardBody(item: item, loader: loader)
        case .code:
            CodeCardBody(text: item.previewText ?? "", query: query)
        case .command:
            Text(CommandText.attributed(item.previewText ?? "", query: query, palette: palette))
                .font(.system(size: 11.5, design: .monospaced))
                .lineSpacing(4)
                .lineLimit(3)
                .foregroundStyle(palette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .url:
            URLCardBody(item: item, query: query, loader: loader)
        case .file:
            FileCardBody(item: item, query: query, loader: loader)
        case .color:
            ColorCardBody(item: item, loader: loader)
        case .other:
            HStack(spacing: 6) {
                Image(systemName: PanelSymbols.kind(.other))
                Text("その他のデータ · " + DisplayText.bytes(item.totalBytes))
            }
            .font(.system(size: 13))
            .foregroundStyle(palette.text2)
        }
    }
}

struct RichCardBody: View {
    let item: ClipItem
    let query: SearchQuery
    let loader: ClipContentLoader
    @Environment(\.palette) private var palette

    var body: some View {
        let rich = loader.cardExtras(for: item).richText
        Group {
            if let rich, query.isEmpty {
                Text(rich)
            } else {
                Text(
                    Highlight.attributed(
                        (item.previewText ?? "").replacingOccurrences(of: "\n", with: "  "), query: query,
                        mark: palette.mark))
            }
        }
        .font(.system(size: 13))
        .lineSpacing(2.5)
        .lineLimit(3)
        .foregroundStyle(palette.text)
        .tint(palette.accentInk)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// コード: 先頭の 5 行を等幅で、折り返さずに右を切る（色付けはフェーズ3）
struct CodeCardBody: View {
    let text: String
    let query: SearchQuery
    @Environment(\.palette) private var palette

    var body: some View {
        let lines = text.replacingOccurrences(of: "\t", with: "    ")
            .split(separator: "\n", omittingEmptySubsequences: false).prefix(5)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(Highlight.attributed(line.isEmpty ? " " : String(line), query: query, mark: palette.mark))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(height: 17.8, alignment: .leading)
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(palette.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

struct ImageCardBody: View {
    let item: ClipItem
    let loader: ClipContentLoader
    @State private var thumb: ImageThumb?
    @Environment(\.palette) private var palette

    init(item: ClipItem, loader: ClipContentLoader) {
        self.item = item
        self.loader = loader
        _thumb = State(initialValue: loader.cachedThumbnail(for: item))
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            palette.fill2
            if let thumb {
                Image(decorative: thumb.image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                DimensionBadge(size: thumb.pixelSize).padding(8)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundStyle(palette.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 96)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: item.contentHash) {
            if thumb == nil { thumb = await loader.thumbnail(for: item) }
        }
    }
}

/// 画像の右下の「1600 × 1000」
struct DimensionBadge: View {
    let size: CGSize

    var body: some View {
        Text("\(Int(size.width)) × \(Int(size.height))")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.5)))
    }
}

struct URLCardBody: View {
    let item: ClipItem
    let query: SearchQuery
    let loader: ClipContentLoader
    @Environment(\.palette) private var palette

    var body: some View {
        let text = (item.previewText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(string: text)
        let title = loader.cardExtras(for: item).urlTitle
        let path = url.map { ($0.path.isEmpty ? "/" : $0.path) + ($0.query.map { "?" + $0 } ?? "") } ?? ""
        VStack(alignment: .leading, spacing: 0) {
            // 題名が取れないとき（ブラウザによっては載せない）は URL そのものを題名の行に出す
            Text(Highlight.attributed(title ?? Self.withoutScheme(text), query: query, mark: palette.mark))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.text)
                .lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: "link").font(.system(size: 10.5))
                Text(url?.host ?? text).lineLimit(1)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(palette.kind(.url))
            .padding(.top, 2)
            if title != nil, !path.isEmpty {
                Text(path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(palette.text3)
                    .lineLimit(2)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func withoutScheme(_ text: String) -> String {
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        return text
    }
}

struct FileCardBody: View {
    let item: ClipItem
    let query: SearchQuery
    let loader: ClipContentLoader
    @Environment(\.palette) private var palette

    var body: some View {
        let files = loader.cardExtras(for: item).files
        let total = max(item.pasteboardItemCount, files.count)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(files.prefix(3).enumerated()), id: \.offset) { _, file in
                HStack(spacing: 6) {
                    Image(systemName: "doc").font(.system(size: 12)).foregroundStyle(palette.kind(.file))
                    Text(Highlight.attributed(file.name, query: query, mark: palette.mark))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if total > 3 {
                Text("他 \(total - 3) 件")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.text3)
                    .padding(.leading, 20)
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ColorCardBody: View {
    let item: ClipItem
    let loader: ClipContentLoader
    @Environment(\.palette) private var palette

    var body: some View {
        let color = loader.cardExtras(for: item).color
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color?.color ?? palette.fill2)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black.opacity(0.2), lineWidth: 0.5))
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(color?.hex ?? (item.previewText ?? "色"))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(palette.text)
                if let color {
                    Text("RGB " + color.rgb.map(String.init).joined(separator: ", "))
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.text2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// カードの下の行（種類・アプリ・相対時刻・コピー方法・ピン）
struct MetaLine: View {
    let item: ClipItem
    let now: Date
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            Text(item.kind.label)
                .fontWeight(.semibold)
                .foregroundStyle(palette.kind(item.kind))
                .fixedSize()
            if let source = item.source {
                MetaDot()
                HStack(spacing: 4) {
                    AppIconView(bundleID: source.bundleID, name: source.name ?? "", size: 12)
                    Text(source.name ?? source.bundleID ?? "")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(-1)
            }
            MetaDot()
            Text(DisplayText.relative(item.lastUsedAt, now: now)).fixedSize()
            if let method = DisplayText.methodShort(item.copyMethod) {
                HStack(spacing: 3) {
                    Image(systemName: PanelSymbols.method(item.copyMethod)).font(.system(size: 9.5))
                    Text(method).font(.system(size: 10.5))
                }
                .foregroundStyle(palette.text3)
                .padding(.leading, 7)
                .fixedSize()
            }
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(palette.kind(.image))
                    .padding(.leading, 6)
                    .help("ピン留め")
            }
        }
        .lineLimit(1)
    }
}

struct MetaDot: View {
    var body: some View {
        Circle().fill(.foreground).opacity(0.55).frame(width: 2.5, height: 2.5).padding(.horizontal, 6)
    }
}

/// 検索語に一致した部分に印を付ける（試作の mark）
enum Highlight {
    static func attributed(_ text: String, query: SearchQuery, mark: Color) -> AttributedString {
        var result = AttributedString(text)
        guard !query.isEmpty else { return result }
        for range in query.highlightRanges(in: text) {
            guard let target = Range(range, in: result) else { continue }
            result[target].backgroundColor = mark
        }
        return result
    }
}

/// コマンド: 行頭の「$ 」「% 」を薄く出す（貼るときに外すのはフェーズ3）
enum CommandText {
    static func attributed(_ text: String, query: SearchQuery, palette: PanelPalette) -> AttributedString {
        var result = AttributedString()
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { result += AttributedString("\n") }
            var body = String(line)
            if body.hasPrefix("$ ") || body.hasPrefix("% ") {
                var prompt = AttributedString(String(body.prefix(2)))
                prompt.foregroundColor = palette.prompt
                result += prompt
                body = String(body.dropFirst(2))
            }
            result += Highlight.attributed(body, query: query, mark: palette.mark)
        }
        return result
    }
}
