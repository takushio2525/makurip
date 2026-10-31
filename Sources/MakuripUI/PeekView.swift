import MakuripCore
import SwiftUI

/// ⌘Y で横に出す大きいプレビュー（470 × パネルと同じ高さ）。選択を動かすと追従する。試作の .peek-panel
struct PeekView: View {
    let model: HistoryPanelModel
    let loader: ClipContentLoader
    @Environment(\.colorScheme) private var scheme

    static let width: CGFloat = 470

    var body: some View {
        Group {
            if let item = model.selected {
                PeekContent(item: item, model: model, loader: loader)
                    .id(item.id)
            } else {
                Color.clear
            }
        }
        .frame(width: Self.width, height: HistoryPanelView.size.height)
        .glassSurface()
        .environment(\.palette, .of(scheme))
    }
}

private struct PeekContent: View {
    let item: ClipItem
    let model: HistoryPanelModel
    let loader: ClipContentLoader
    @State private var detail: ClipDetail
    @Environment(\.palette) private var palette

    init(item: ClipItem, model: HistoryPanelModel, loader: ClipContentLoader) {
        self.item = item
        self.model = model
        self.loader = loader
        _detail = State(initialValue: loader.detail(for: item))
    }

    /// 内容の要点（秘密は「API キーの形式 · 36 文字」。中身の数え方は本当の中身で）
    private var info: String {
        guard SecretDisplay.masks(item) else { return DisplayText.info(for: item, detail: detail) }
        let secret = loader.secret(for: item)
        return DisplayText.secretInfo(reason: secret.reason, characters: secret.characterCount)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                KindBadge(kind: item.kind)
                if item.isSecretLikely { SecretBadge() }
                Text(info)
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
            Group {
                if SecretDisplay.masks(item) {
                    SecretPreviewBody(item: item, model: model, loader: loader)
                } else {
                    PreviewBody(item: item, detail: detail, query: model.searchQuery, model: model, loader: loader)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.well))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
                    palette.wellLine, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 12)
            DetailsGrid(item: item, detail: detail, info: info, now: model.now, model: model)
                .padding(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
        }
        .task(id: item.contentHash) {
            // 画像は大きい縮小版を別のスレッドで作ってから差し替える
            if item.kind == .image,
                let large = await loader.thumbnail(for: item, size: ClipContentLoader.previewPixelSize)
            {
                detail.image = large
            }
        }
    }
}

/// 種類の札（色付き）
struct KindBadge: View {
    let kind: ClipKind
    @Environment(\.palette) private var palette

    var body: some View {
        let color = palette.kind(kind)
        HStack(spacing: 4) {
            Image(systemName: PanelSymbols.kind(kind)).font(.system(size: 10.5))
            Text(kind.label)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.14)))
    }
}

/// プレビューの本文（種類ごと）
private struct PreviewBody: View {
    let item: ClipItem
    let detail: ClipDetail
    let query: SearchQuery
    let model: HistoryPanelModel
    let loader: ClipContentLoader
    @Environment(\.palette) private var palette

    var body: some View {
        switch item.kind {
        case .image:
            imageBody
        case .color:
            colorBody.padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .code:
            // コードは NSTextView が縦横に送る（上下の padding は中身と一緒に送られるよう NSTextView の中に持つ）
            VStack(alignment: .leading, spacing: 0) {
                CodePreview(item: item, text: DisplayText.codeText(text), query: query, loader: loader)
                if detail.textTruncated {
                    truncatedNote.padding(.bottom, 12)
                }
            }
            .padding(.horizontal, 18)
        default:
            ScrollView([.vertical]) {
                textualBody
                    .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var text: String { detail.fullText ?? item.previewText ?? "" }

    @ViewBuilder private var textualBody: some View {
        switch item.kind {
        case .text, .other:
            VStack(alignment: .leading, spacing: 10) {
                Text(Highlight.attributed(text, query: query, mark: palette.mark))
                    .css(CSS.previewText)
                    .textSelection(.enabled)
                truncatedNote
            }
        case .richText:
            VStack(alignment: .leading, spacing: 10) {
                if let rich = detail.richText {
                    Text(rich).css(CSS.previewRich).textSelection(.enabled).tint(palette.accentInk)
                } else {
                    Text(Highlight.attributed(text, query: query, mark: palette.mark))
                        .css(CSS.previewRich)
                        .textSelection(.enabled)
                }
                truncatedNote
            }
        case .command:
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    loader.commandPreview(
                        for: item, text: DisplayText.codeText(text), palette: palette, query: query)
                )
                .css(CSS.previewCommand)
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
                if detail.promptCount > 0 { promptNote }
            }
        case .url:
            urlBody
        case .file:
            filesBody
        case .image, .color, .code:
            EmptyView()
        }
    }

    /// コマンドの先頭の記号を外して貼ることの説明（試作の .pv-note）。外さずに貼るキーはキーマップから引く
    private var promptNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: PanelSymbols.kind(.command)).font(.system(size: 11))
            VStack(alignment: .leading, spacing: 4) {
                Text("貼り付けるときは、先頭の「$ 」などのプロンプトを外します。")
                if let combo = model.keymap.primary(.pastePlain) {
                    HStack(spacing: 5) {
                        KeyChip(combo)
                        Text("なら外さずにそのまま貼ります。")
                    }
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(palette.text2)
    }

    @ViewBuilder private var truncatedNote: some View {
        if detail.textTruncated {
            Text(verbatim: "長いので先頭の \(ClipContentLoader.previewCharacterLimit) 文字だけを表示しています（貼るときは全文が入ります）")
                .font(.system(size: 12))
                .foregroundStyle(palette.text2)
        }
    }

    private var imageBody: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image = detail.image {
                Image(decorative: image.image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                DimensionBadge(size: image.pixelSize).padding(8)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 34))
                    .foregroundStyle(palette.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
    }

    private var urlBody: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = URL(string: trimmed)?.host ?? trimmed
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.kind(.url))
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 9).fill(palette.kind(.url).opacity(0.14)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Highlight.attributed(detail.urlTitle ?? host, query: query, mark: palette.mark))
                            .font(.system(size: 15, weight: .semibold))
                        Text(host).font(.system(size: 12)).foregroundStyle(palette.text2)
                    }
                }
                Text(Highlight.attributed(trimmed, query: query, mark: palette.mark))
                    .css(CSS.previewURL)
                    .foregroundStyle(palette.accentInk)
                    .textSelection(.enabled)
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.well))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.wellLine, lineWidth: 0.5))
            if let combo = model.keymap.primary(.openSource) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.up.right").font(.system(size: 11))
                    KeyChip(combo)
                    Text("でブラウザで開きます。")
                }
                .font(.system(size: 12))
                .foregroundStyle(palette.text2)
            }
        }
    }

    private var filesBody: some View {
        VStack(spacing: 6) {
            ForEach(Array(detail.files.enumerated()), id: \.offset) { _, file in
                HStack(spacing: 12) {
                    ZStack(alignment: .bottom) {
                        Image(systemName: "doc").font(.system(size: 26, weight: .light))
                        Text((file.name as NSString).pathExtension.uppercased().prefix(4))
                            .font(.system(size: 6.5, weight: .bold))
                            .padding(.bottom, 5)
                    }
                    .foregroundStyle(palette.kind(.file))
                    .frame(width: 30, height: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Highlight.attributed(file.name, query: query, mark: palette.mark))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !file.displayPath.isEmpty {
                            Text(file.displayPath)
                                .font(CSSText.mono(11))
                                .foregroundStyle(palette.text3)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let size = file.byteCount {
                        Text(DisplayText.bytes(size)).font(.system(size: 12)).foregroundStyle(palette.text2)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.well))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.wellLine, lineWidth: 0.5))
            }
        }
    }

    @ViewBuilder private var colorBody: some View {
        if let color = detail.color {
            HStack(spacing: 20) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(color.color)
                    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.black.opacity(0.2), lineWidth: 0.5))
                    .frame(width: 132, height: 132)
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 8)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                    colorRow("HEX", color.hex)
                    colorRow("RGB", color.rgb.map(String.init).joined(separator: ", "))
                    let hsl = color.hsl
                    colorRow("HSL", "\(hsl[0])°, \(hsl[1])%, \(hsl[2])%")
                }
            }
        } else {
            Text(text).font(CSSText.mono(14))
        }
    }

    private func colorRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.system(size: 11)).foregroundStyle(palette.text3).frame(width: 34, alignment: .leading)
            Text(value).font(CSSText.mono(14)).textSelection(.enabled)
        }
    }
}

/// コード: 行番号と、言語ごとに色を付けた等幅の本文（試作の .pv-code）。短いものはその場で（キャッシュから）、
/// 長いものは裏で色付けの区間を作り、できるまでは色なしで出す
private struct CodePreview: View {
    let item: ClipItem
    let text: String
    let query: SearchQuery
    let loader: ClipContentLoader
    /// 裏で作った区間（作ったときの鍵と一緒に持ち、別の項目に変わったら使わない）
    @State private var late: (key: String, tokens: [SyntaxToken])?
    @Environment(\.palette) private var palette

    var body: some View {
        let key = "\(item.id.uuidString)-\(item.contentHash)"
        let tokens = loader.cachedCodeTokens(for: item, text: text) ?? (late?.key == key ? late?.tokens : nil)
        CodeTextView(contentKey: key, text: text, tokens: tokens, query: query, palette: palette)
            .task(id: key) {
                guard tokens == nil else { return }
                let value = await loader.codeTokens(for: item, text: text)
                late = (key, value)
            }
    }
}

/// コピー元・コピー方法・日時・内容・コピー元のページ
private struct DetailsGrid: View {
    let item: ClipItem
    let detail: ClipDetail
    let info: String
    let now: Date
    let model: HistoryPanelModel
    @Environment(\.palette) private var palette

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                cell("コピー元") {
                    if let source = item.source {
                        AppIconView(bundleID: source.bundleID, name: source.name ?? "", size: 14)
                        Text(source.name ?? source.bundleID ?? "").lineLimit(1)
                    } else {
                        Text("不明").foregroundStyle(palette.text3)
                    }
                }
                cell("コピー方法") {
                    Image(systemName: PanelSymbols.method(item.copyMethod))
                        .font(.system(size: 10.5))
                        .foregroundStyle(palette.text3)
                    Text(DisplayText.methodLong(item.copyMethod)).lineLimit(1)
                }
            }
            GridRow {
                cell("日時") {
                    Text(DisplayText.absolute(item.lastUsedAt, now: now))
                    Text(verbatim: "（\(DisplayText.relative(item.lastUsedAt, now: now))）").foregroundStyle(
                        palette.text3)
                }
                cell("内容") {
                    Text(info).lineLimit(1)
                }
            }
            // コピー元のページ（取れたときだけ。試作の .src: 題名の代わりにホストを、薄い字でパスを出す）
            if let page = DisplayText.sourcePage(item.sourceURL) {
                GridRow {
                    cell("コピー元のページ") {
                        Image(systemName: "arrow.up.right").font(.system(size: 10))
                        Text(sourceLabel(page))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(palette.accentInk)
                    .onTapGesture { model.openSource() }
                    .gridCellColumns(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceLabel(_ page: (host: String, path: String)) -> AttributedString {
        var label = AttributedString(page.host)
        if !page.path.isEmpty {
            var path = AttributedString("　" + page.path)
            path.foregroundColor = palette.text3
            label += path
        }
        return label
    }

    private func cell<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).css(CSS.detailTitle).foregroundStyle(palette.text3)
            HStack(spacing: 6) { content() }.css(CSS.detailValue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
