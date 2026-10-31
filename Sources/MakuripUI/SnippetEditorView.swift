import AppKit
import MakuripCore
import SwiftUI

/// 定型文の窓の寸法（設定の窓と同じ作り。試作に定型文の窓はないので、設定シートの寸法と色にそろえた）
enum SnippetEditorCSS {
    static let width: CGFloat = 680
    static let height: CGFloat = 560
    static let listWidth: CGFloat = 232
    static let label = CSSText(11, lineHeight: 1.45, weight: .semibold)
    static let rowName = CSSText(13, lineHeight: 1.45)
    static let rowDetail = CSSText(11, lineHeight: 1.45)
    static let body = CSSText(13, lineHeight: 1.6)
}

/// 定型文の窓の中身。左に一覧（並べ替え）、右に名前・略語・本文と差し込みの札
struct SnippetEditorView: View {
    @Bindable var model: SnippetEditorModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = PanelPalette.of(scheme)
        let colors = SettingsPalette.of(scheme)
        VStack(spacing: 0) {
            SettingsTitleBar(title: "Makurip 定型文")
            Text(Self.lead)
                .css(SettingsCSS.lead)
                .foregroundStyle(palette.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 12, leading: 20, bottom: 10, trailing: 20))
            if !model.issues.isEmpty {
                SnippetIssuesView(issues: model.issues).padding(.horizontal, 20).padding(.bottom, 10)
            }
            HStack(spacing: 0) {
                SnippetEditorList(model: model)
                    .frame(width: SnippetEditorCSS.listWidth)
                Rectangle().fill(palette.sep).frame(width: 0.5)
                if model.selection == nil {
                    SnippetEditorEmpty(model: model)
                } else {
                    SnippetEditorForm(model: model)
                }
            }
            .overlay(alignment: .top) { Rectangle().fill(palette.sep).frame(height: 0.5) }
            if let message = model.message {
                Text(message.text)
                    .css(SettingsCSS.message)
                    .foregroundStyle(message.isError ? colors.warning : palette.accentInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .overlay(alignment: .top) { Rectangle().fill(palette.sep).frame(height: 0.5) }
            }
            SnippetEditorFooter(model: model)
        }
        .frame(minWidth: SnippetEditorCSS.width, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(colors.windowBackground)
        .environment(\.palette, palette)
    }

    static let lead =
        "よく使う文を登録しておくと、履歴の一覧で ⌘S を押して貼れます。色の付いた差し込みは、貼るときに置き換わります。並びは一覧の順（⌘1〜9 の番号）です。"
}

/// 左の一覧
private struct SnippetEditorList: View {
    @Bindable var model: SnippetEditorModel
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.snippets.enumerated()), id: \.element.id) { index, snippet in
                            SnippetEditorRow(
                                number: index + 1, name: snippet.name, abbreviation: snippet.abbreviation,
                                detail: Self.firstLine(snippet.body),
                                selected: model.selection == .snippet(snippet.id)
                            )
                            .id(snippet.id)
                            .onTapGesture { model.select(snippet.id) }
                        }
                        if model.isDraft {
                            SnippetEditorRow(
                                number: nil, name: model.draftTitle, abbreviation: model.draft.abbreviation,
                                detail: "未保存", selected: true
                            )
                            .id("draft")
                        }
                    }
                    .padding(8)
                }
                .onChange(of: model.selection) { _, selection in
                    switch selection {
                    case .snippet(let id): proxy.scrollTo(id)
                    case .draft: proxy.scrollTo("draft")
                    case nil: break
                    }
                }
            }
            HStack(spacing: 6) {
                SettingsSmallButton(title: "新規") { model.beginNew() }
                Spacer(minLength: 0)
                SnippetIconButton(symbol: "arrow.up", help: "上へ（⌥⌘↑）", disabled: model.selectedSnippet == nil) {
                    model.moveSelected(by: -1)
                }
                SnippetIconButton(symbol: "arrow.down", help: "下へ（⌥⌘↓）", disabled: model.selectedSnippet == nil) {
                    model.moveSelected(by: 1)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .overlay(alignment: .top) { Rectangle().fill(palette.sep).frame(height: 0.5) }
        }
    }

    static func firstLine(_ body: String) -> String {
        body.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first {
            !$0.isEmpty
        } ?? ""
    }
}

private struct SnippetEditorRow: View {
    let number: Int?
    let name: String
    let abbreviation: String
    let detail: String
    let selected: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number.map { $0 <= 9 ? String($0) : "" } ?? "")
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(palette.text3)
                .frame(width: 12, alignment: .trailing)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(name).css(SnippetEditorCSS.rowName).foregroundStyle(palette.text).lineLimit(1)
                    Spacer(minLength: 0)
                    if !abbreviation.isEmpty {
                        Text(abbreviation).font(CSSText.mono(10.5)).foregroundStyle(palette.snippet).lineLimit(1)
                            .layoutPriority(-1)
                    }
                }
                Text(detail).css(SnippetEditorCSS.rowDetail).foregroundStyle(palette.text3).lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? palette.accentSoft : .clear))
        .contentShape(Rectangle())
    }
}

/// 右の入力欄
private struct SnippetEditorForm: View {
    @Bindable var model: SnippetEditorModel
    @FocusState private var focus: SnippetEditorModel.Field?
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                field("名前", note: "空なら本文の 1 行目") {
                    TextField(
                        "", text: $model.draft.name, prompt: Text(model.draftTitle).foregroundStyle(palette.text3)
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focus, equals: .name)
                }
                field("略語", note: "検索で引ける語") {
                    TextField("", text: $model.draft.abbreviation, prompt: Text(";date").foregroundStyle(palette.text3))
                        .textFieldStyle(.plain)
                        .font(CSSText.mono(12.5))
                        .focused($focus, equals: .abbreviation)
                }
                .frame(width: 150)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("本文").css(SnippetEditorCSS.label).foregroundStyle(palette.text3)
                SnippetBodyEditor(model: model, palette: palette, focused: focus == .body) { focused in
                    if focused { focus = .body }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.well))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(
                        focus == .body ? palette.accent.opacity(0.6) : palette.wellLine,
                        lineWidth: focus == .body ? 1 : 0.5)
                )
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("差し込み").css(SnippetEditorCSS.label).foregroundStyle(palette.text3)
                    ForEach(SnippetPlaceholder.allCases, id: \.self) { placeholder in
                        SnippetPlaceholderButton(placeholder: placeholder, help: model.placeholderSummary(placeholder))
                        {
                            model.insert(placeholder)
                        }
                    }
                }
                Text(Self.note(model))
                    .css(SettingsCSS.detail)
                    .foregroundStyle(palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.focusRequest?.revision) { _, _ in
            guard let request = model.focusRequest else { return }
            focus = request.field
        }
    }

    static func note(_ model: SnippetEditorModel) -> String {
        "押すと文字カーソルの位置に入ります。"
            + SnippetPlaceholder.allCases.map { "\($0.rawValue) → \(model.placeholderSummary($0))" }
            .joined(separator: "、") + "。"
    }

    private func field<Content: View>(_ title: String, note: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title).css(SnippetEditorCSS.label).foregroundStyle(palette.text3)
                Text(note).font(.system(size: 10.5)).foregroundStyle(palette.text3)
            }
            content()
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.fill1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.sep, lineWidth: 0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 差し込みを入れる札（パネルのカードの札と同じ見た目）
private struct SnippetPlaceholderButton: View {
    let placeholder: SnippetPlaceholder
    let help: String
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Text(placeholder.rawValue)
            .font(.system(size: 11.5))
            .foregroundStyle(palette.snippet)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(palette.snippet.opacity(0.15)))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help(help)
    }
}

private struct SnippetIconButton: View {
    let symbol: String
    let help: String
    let disabled: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(palette.text2)
            .frame(width: 26, height: 24)
            .background(palette.fill2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { if !disabled { action() } }
            .opacity(disabled ? 0.35 : 1)
            .help(help)
    }
}

/// 定型文が 1 件もなく、下書きもないとき
private struct SnippetEditorEmpty: View {
    let model: SnippetEditorModel
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: PanelSymbols.snippet)
                .font(.system(size: 22))
                .foregroundStyle(palette.text3)
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.fill1))
                .padding(.bottom, 6)
            Text("定型文はまだありません").css(CSS.emptyTitle).foregroundStyle(palette.text)
            Text("「新規」（⌘N）で作ります。").css(CSS.emptyText).foregroundStyle(palette.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 読めない項目があったときの注記（設定の窓と同じ形）
private struct SnippetIssuesView: View {
    let issues: [String]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors = SettingsPalette.of(scheme)
        VStack(alignment: .leading, spacing: 2) {
            Text("定型文のファイルに読めない項目があったので、その項目は使っていません。次に保存するとき、元のファイルを snippets.broken.json に残します。")
                .css(SettingsCSS.detail)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(issues.prefix(3).enumerated()), id: \.offset) { _, issue in
                Text(issue).css(SettingsCSS.detail).lineLimit(2)
            }
        }
        .foregroundStyle(colors.warning)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .background(colors.warningSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// 下の段（キーのヒントと、削除・保存）
private struct SnippetEditorFooter: View {
    let model: SnippetEditorModel
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 12) {
                Hint(combos: [KeyCombo(.code(45), .command)], label: "新規")
                Hint(combos: [KeyCombo(.code(1), .command)], label: "保存")
                Hint(
                    combos: [
                        KeyCombo(.code(KeyCodes.upArrow), [.option, .command]),
                        KeyCombo(.code(KeyCodes.downArrow), [.option, .command]),
                    ], label: "並べ替え")
                Hint(combos: [KeyCombo(.code(KeyCodes.escape))], label: model.isDirty || model.isDraft ? "取り消す" : "閉じる")
            }
            .font(.system(size: 11.5))
            Spacer(minLength: 0)
            Text("削除")
                .font(.system(size: 12))
                .foregroundStyle(SettingsPalette.of(scheme).warning)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(palette.fill2, in: Capsule())
                .contentShape(Capsule())
                .onTapGesture { model.deleteSelected() }
                .opacity(model.selection == nil ? 0.35 : 1)
            Text("保存")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 26)
                .background(palette.accent, in: Capsule())
                .contentShape(Capsule())
                .onTapGesture { model.save() }
                .opacity(model.selection == nil ? 0.35 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(palette.sep).frame(height: 0.5) }
    }
}

/// 本文の入力欄（NSTextView）。差し込み（`{{日付}}` など）に定型文の色を付け、札のボタンは選択範囲に入れる。
/// 色は一時的な属性（`NSLayoutManager.temporaryAttributes`）で付ける（打った文字に色が移らず、取り消しの履歴にも乗らない）
struct SnippetBodyEditor: NSViewRepresentable {
    @Bindable var model: SnippetEditorModel
    let palette: PanelPalette
    let focused: Bool
    let focusChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.delegate = context.coordinator
        text.drawsBackground = false
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.textContainerInset = NSSize(width: 6, height: 8)
        text.font = NSFont.systemFont(ofSize: SnippetEditorCSS.body.size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = SnippetEditorCSS.body.extra
        text.defaultParagraphStyle = paragraph
        text.typingAttributes[.paragraphStyle] = paragraph
        text.string = model.draft.body
        context.coordinator.textView = text
        context.coordinator.apply(palette: palette)
        context.coordinator.lastRevision = model.bodySelectionRevision
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let text = coordinator.textView else { return }
        text.textColor = NSColor(palette.text)
        text.insertionPointColor = NSColor(palette.accent)
        if text.string != model.draft.body {
            text.string = model.draft.body
        }
        if coordinator.lastRevision != model.bodySelectionRevision {
            coordinator.lastRevision = model.bodySelectionRevision
            let length = (text.string as NSString).length
            let range = model.bodySelection
            text.setSelectedRange(NSRange(location: min(range.location, length), length: 0))
            if focused, text.window?.firstResponder !== text { text.window?.makeFirstResponder(text) }
        }
        coordinator.apply(palette: palette)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: SnippetEditorModel
        weak var textView: NSTextView?
        var lastRevision = 0
        private var palette: PanelPalette?

        init(model: SnippetEditorModel) {
            self.model = model
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if model.draft.body != textView.string { model.draft.body = textView.string }
            if let palette { highlight(textView, palette: palette) }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            model.bodySelection = textView.selectedRange()
        }

        func apply(palette: PanelPalette) {
            self.palette = palette
            guard let textView else { return }
            highlight(textView, palette: palette)
        }

        /// 差し込みに色を付け直す（本文が 10 万文字でも 1 回なめるだけ）
        private func highlight(_ textView: NSTextView, palette: PanelPalette) {
            guard let layout = textView.layoutManager else { return }
            let string = textView.string
            let whole = NSRange(location: 0, length: (string as NSString).length)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
            let ink = NSColor(palette.snippet)
            for (range, _) in SnippetTemplate.placeholderRanges(in: string) {
                layout.addTemporaryAttributes(
                    [.foregroundColor: ink, .backgroundColor: ink.withAlphaComponent(0.15)],
                    forCharacterRange: NSRange(range, in: string))
            }
        }
    }
}
