import AppKit
import MakuripCore
import Observation
import SwiftUI

/// 候補窓の状態（画面に出す分だけ）。本体の `CandidateCoordinator` から `CandidateViewState` を受け取り、
/// 見えている 8 行の範囲と、窓の位置に使う「選んでいる行までの距離」を決める
@MainActor
@Observable
final class CandidateViewModel {
    struct Row: Identifiable {
        /// `items` の添字（0 が最新）
        let index: Int
        let item: ClipItem
        var id: UUID { item.id }
    }

    var keymap: Keymap
    private(set) var state: CandidateViewState?
    /// 見えている行の先頭（画面の上から数えた行の番号）
    private(set) var firstVisibleRow = 0
    /// 端で動けなかったときに揺らす（値が変わるたびに 1 回）
    private(set) var shakeCount = 0
    @ObservationIgnored var onClick: (Int) -> Void = { _ in }
    @ObservationIgnored var onDoubleClick: (Int) -> Void = { _ in }

    init(keymap: Keymap) {
        self.keymap = keymap
    }

    func update(_ new: CandidateViewState) {
        let selectedRow = Self.visualRow(new.selectedIndex, count: new.items.count, order: new.order)
        firstVisibleRow = CandidateLayout.firstVisibleRow(selectedRow: selectedRow, rowCount: new.items.count)
        state = new
    }

    func bump() { shakeCount += 1 }

    var items: [ClipItem] { state?.items ?? [] }
    var isEmpty: Bool { items.isEmpty }
    var selectedIndex: Int { state?.selectedIndex ?? 0 }
    var note: CandidateNote? { state?.note }
    var order: CandidateOrder { state?.order ?? .terminal }

    static func visualRow(_ index: Int, count: Int, order: CandidateOrder) -> Int {
        order == .terminal ? count - 1 - index : index
    }

    /// 画面の上から順に、見えている行
    var visibleRows: [Row] {
        let count = items.count
        let visible = CandidateLayout.visibleRowCount(count)
        return (firstVisibleRow..<(firstVisibleRow + visible)).map { row in
            let index = order == .terminal ? count - 1 - row : row
            return Row(index: index, item: items[index])
        }
    }

    var selectedVisibleRow: Int {
        Self.visualRow(selectedIndex, count: items.count, order: order) - firstVisibleRow
    }

    /// 窓の上端から、選んでいる行の中心までの距離（`PanelPlacement.Side.beside` に渡す）
    var rowOffset: CGFloat {
        isEmpty ? CandidateLayout.emptyRowOffset : CandidateLayout.rowOffset(visibleRow: selectedVisibleRow)
    }

    var windowSize: CGSize {
        CGSize(
            width: CandidateLayout.width,
            height: CandidateLayout.windowHeight(rowCount: items.count, hasNote: note != nil))
    }

    /// 新しいほうから数えた番号（試作の「4 / 27」）
    var positionText: String { "\(selectedIndex + 1) / \(items.count)" }
}

/// 候補の 1 行に出す文言（純粋関数）。試作（`shared/candidate.js` の sub と core.js の titleHTML）と同じ決まり
enum CandidateRowText {
    struct Title: Equatable {
        /// コマンドの先頭の「$」「%」（薄く出す）
        var prompt: String?
        var body: String
        var mono: Bool
    }

    /// 最初の空でない行（前後の空白を除く。試作の firstLine）
    static func firstLine(_ text: String?) -> String {
        guard let text else { return "" }
        let line = text.split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return line.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    static func lineCount(_ text: String?) -> Int {
        guard let text, !text.isEmpty else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// 平文が一覧用の上限（先頭 1000 文字）で切れているか。切れていれば数のあとに「+」を付ける
    static func isTruncated(_ text: String?) -> Bool {
        (text?.count ?? 0) >= Limits.default.previewCharacterLimit
    }

    static func title(_ item: ClipItem, urlTitle: String? = nil, fileName: String? = nil, colorHex: String? = nil)
        -> Title
    {
        let text = item.previewText
        switch item.kind {
        case .command:
            let line = firstLine(text)
            for prompt in ["$ ", "% "] where line.hasPrefix(prompt) {
                return Title(prompt: String(prompt.prefix(1)), body: String(line.dropFirst(2)), mono: true)
            }
            return Title(body: line, mono: true)
        case .code:
            return Title(body: firstLine(text), mono: true)
        case .color:
            return Title(body: colorHex ?? firstLine(text), mono: true)
        case .url:
            if let urlTitle = urlTitle.map(firstLine), !urlTitle.isEmpty { return Title(body: urlTitle, mono: false) }
            let url = firstLine(text)
            let bare = url.range(of: "://").map { String(url[$0.upperBound...]) } ?? url
            return Title(body: bare, mono: false)
        case .file:
            return Title(body: fileName ?? firstLine(text), mono: false)
        case .image:
            return Title(body: imageName(source: item.source?.name), mono: false)
        case .text, .richText:
            let line = firstLine(text)
            return Title(body: line.isEmpty ? "（空白だけ）" : line, mono: false)
        case .other:
            return Title(body: firstLine(text).isEmpty ? "その他のデータ" : firstLine(text), mono: false)
        }
    }

    /// 画像には名前がないので、コピー元のアプリから呼ぶ（「スクリーンショットの画像」「Safari の画像」）
    static func imageName(source: String?) -> String {
        guard let source, let last = source.unicodeScalars.last else { return "画像" }
        return last.isASCII ? "\(source) の画像" : "\(source)の画像"
    }

    /// 右に薄い字で出す種類と補足（予測変換の「ひらがな」の位置）。コードは言語が分かれば言語名（試作の「Swift 17行」）
    static func detail(_ item: ClipItem, imageSize: CGSize? = nil, language: CodeLanguage? = nil) -> String {
        let text = item.previewText
        let plus = isTruncated(text) ? "+" : ""
        switch item.kind {
        case .code:
            return "\(language?.displayName ?? "コード") \(lineCount(text))\(plus)行"
        case .command:
            let lines = lineCount(text)
            return lines > 1 ? "コマンド \(lines)\(plus)行" : "コマンド"
        case .text:
            let length = text?.count ?? 0
            return lineCount(text) > 1 || length > 40 ? "テキスト \(length)\(plus)字" : "テキスト"
        case .richText:
            return "リッチテキスト"
        case .image:
            guard let imageSize else { return "画像" }
            return "画像 \(Int(imageSize.width))×\(Int(imageSize.height))"
        case .file:
            return item.pasteboardItemCount > 1 ? "ファイル \(item.pasteboardItemCount)件" : "ファイル"
        case .url:
            return "URL"
        case .color:
            return "色"
        case .other:
            return "その他"
        }
    }
}

/// 候補窓（試作の `.mk-cand`）。縦の 1 行リストと、下段のキーのヒント
struct CandidateView: View {
    let model: CandidateViewModel
    let loader: ClipContentLoader
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        CandidateContent(model: model, loader: loader)
            .environment(\.palette, .of(scheme))
    }
}

private struct CandidateContent: View {
    let model: CandidateViewModel
    let loader: ClipContentLoader
    @Environment(\.palette) private var palette
    @State private var shake: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if model.isEmpty {
                Text("履歴はまだありません。コピーするとここに並びます。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.text2)
                    .frame(maxWidth: .infinity)
                    .frame(height: CandidateLayout.emptyHeight)
            } else {
                VStack(spacing: CandidateLayout.rowGap) {
                    ForEach(model.visibleRows) { row in
                        CandidateRowView(item: row.item, selected: row.index == model.selectedIndex, loader: loader)
                            .onTapGesture(count: 2) { model.onDoubleClick(row.index) }
                            .onTapGesture { model.onClick(row.index) }
                    }
                }
            }
            if let note = model.note { CandidateNoteView(note: note) }
            CandidateFooter(model: model)
        }
        .padding(CandidateLayout.padding)
        .frame(width: model.windowSize.width, height: model.windowSize.height, alignment: .top)
        .font(.system(size: 13))
        .foregroundStyle(palette.text)
        .glassSurface(cornerRadius: 16)
        .modifier(ShakeEffect(animatableData: shake))
        .onChange(of: model.shakeCount) { _, _ in
            shake = 0
            withAnimation(.linear(duration: 0.3)) { shake = 1 }
        }
    }
}

/// 候補 1 行（試作の `.cd-row`）: 種類の札・1 行目・右に薄い字の種類と補足
struct CandidateRowView: View {
    let item: ClipItem
    let selected: Bool
    let loader: ClipContentLoader
    @Environment(\.palette) private var palette
    @State private var thumb: ImageThumb?

    /// 札（20pt）のサムネイルの長辺（画素）
    static let thumbnailPixels: CGFloat = 64

    var body: some View {
        let extras = loader.cardExtras(for: item)
        let image = currentThumb
        let title = CandidateRowText.title(
            item, urlTitle: extras.urlTitle, fileName: extras.files.first?.name, colorHex: extras.color?.hex)
        HStack(spacing: 8) {
            CandidateTile(item: item, selected: selected, thumb: image, color: extras.color)
            Text(attributed(title))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(CandidateRowText.detail(item, imageSize: image?.pixelSize, language: loader.language(for: item)))
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.white.opacity(0.78) : palette.text3)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.leading, 5)
        .padding(.trailing, 9)
        .frame(height: CandidateLayout.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? palette.accent : Color.clear)
        )
        .foregroundStyle(selected ? Color.white : palette.text)
        .contentShape(Rectangle())
        .task(id: item.id) {
            guard item.kind == .image, thumb == nil else { return }
            thumb = await loader.thumbnail(for: item, size: Self.thumbnailPixels)
        }
    }

    private var currentThumb: ImageThumb? {
        guard item.kind == .image else { return nil }
        return thumb ?? loader.cachedThumbnail(for: item, size: Self.thumbnailPixels)
    }

    private func attributed(_ title: CandidateRowText.Title) -> AttributedString {
        let font = title.mono ? CSSText.mono(12) : Font.system(size: 13)
        var result = AttributedString()
        if let prompt = title.prompt {
            var run = AttributedString(prompt + " ")
            run.foregroundColor = selected ? Color.white.opacity(0.78) : palette.prompt
            result += run
        }
        result += AttributedString(title.body)
        result.font = font
        return result
    }
}

/// 種類の札（試作の `.ktile` 20px・角 6px）。画像はサムネイル、色は見本の色
struct CandidateTile: View {
    let item: ClipItem
    let selected: Bool
    let thumb: ImageThumb?
    let color: ColorInfo?
    @Environment(\.palette) private var palette

    static let size: CGFloat = 20

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Group {
            switch item.kind {
            case .image:
                ZStack {
                    palette.fill2
                    if let thumb {
                        Image(decorative: thumb.image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: Self.size, height: Self.size)
                    }
                }
                .frame(width: Self.size, height: Self.size)
                .clipShape(shape)
                .overlay(shape.strokeBorder(palette.sep, lineWidth: 0.5))
            case .color:
                shape.fill(color?.color ?? palette.fill2)
                    .overlay(shape.strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5))
            default:
                let tint = palette.kind(item.kind)
                shape.fill(selected ? Color.white.opacity(0.22) : tint.opacity(0.15))
                    .overlay {
                        if !selected { shape.strokeBorder(tint.opacity(0.22), lineWidth: 0.5) }
                    }
                    .overlay(
                        Image(systemName: PanelSymbols.kind(item.kind))
                            .font(.system(size: 8.5))
                            .foregroundStyle(selected ? Color.white : tint)
                            .environment(\.locale, Locale(identifier: "en_US")))
            }
        }
        .frame(width: Self.size, height: Self.size)
    }
}

/// 仮に貼らない理由（試作の `.cd-note` の形。色は秘密の赤でなく、知らせの青にした）
struct CandidateNoteView: View {
    let note: CandidateNote
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(palette.accent)
            Text(note.text)
                .font(.system(size: 11.5))
                .foregroundStyle(palette.text2)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(height: CandidateLayout.noteHeight - 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.accent.opacity(0.09)))
        .padding(.horizontal, 2)
        .padding(.top, 6)
    }
}

/// 最下段のキーのヒント（↑↓ たどる・⇥ 確定・esc 取り消し・⌃⌘V 一覧）と、新しいほうから数えた番号
struct CandidateFooter: View {
    let model: CandidateViewModel
    @Environment(\.palette) private var palette

    var body: some View {
        let keymap = model.keymap
        VStack(spacing: 0) {
            Rectangle().fill(palette.sep).frame(height: 0.5)
            HStack(spacing: 9) {
                if model.isEmpty {
                    CandidateHint(combos: [keymap.primary(.candidateCancel)], label: "閉じる")
                    CandidateHint(combos: [keymap.primary(.candidateExpand)], label: "一覧")
                } else {
                    CandidateHint(
                        combos: [keymap.primary(.candidateUp), keymap.primary(.candidateDown)], label: "たどる")
                    CandidateHint(combos: [keymap.primary(.candidateCommit)], label: "確定")
                    CandidateHint(combos: [keymap.primary(.candidateCancel)], label: "取り消し")
                    CandidateHint(combos: [keymap.primary(.candidateExpand)], label: "一覧")
                }
                Spacer(minLength: 0)
                if !model.isEmpty {
                    Text(model.positionText)
                        .monospacedDigit()
                        .foregroundStyle(palette.text3)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 4)
            .padding(.top, 7)
            .padding(.bottom, 1)
            .frame(height: CandidateLayout.footerHeight - 6.5)
        }
        .padding(.top, 6)
    }
}

/// キー + 説明（試作の `.hint`。候補窓の `.cd-foot .kb` は高さ 18px・10.5px で、一覧の Hint より小さい）
struct CandidateHint: View {
    let combos: [KeyCombo?]
    let label: String
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                ForEach(Array(combos.compactMap { $0 }.enumerated()), id: \.offset) { _, combo in
                    CandidateKeyChip(combo: combo)
                }
            }
            Text(label).foregroundStyle(palette.text2)
        }
        .fixedSize()
    }
}

/// キーの表示（`KeyChip` を候補窓の寸法で写したもの。Return は記号で出す）
struct CandidateKeyChip: View {
    let combo: KeyCombo
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if combo.isReturn {
                HStack(spacing: 1) {
                    if !combo.modifierSymbols.isEmpty { Text(combo.modifierSymbols) }
                    Image(systemName: "return").font(.system(size: 9, weight: .medium))
                }
            } else {
                Text(verbatim: combo.displayString)
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(palette.text2)
        .padding(.horizontal, 5)
        .frame(minWidth: 18, minHeight: 18, maxHeight: 18)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(palette.kbBg))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(palette.kbLine, lineWidth: 0.5))
        .fixedSize()
    }
}
