import AppKit
import MakuripCore
import SwiftUI

/// 設定窓の色（試作の base.css の --win-bg・--win-bar・--seg-on）。ほかの色はパネルと同じ `PanelPalette`
struct SettingsPalette {
    let windowBackground: Color
    let bar: Color
    let segmentOn: Color
    /// 重なり・登録の失敗の注記（試作に無い。種類「ファイル」の橙を使う）
    let warning: Color
    let warningSoft: Color

    static func of(_ scheme: ColorScheme) -> SettingsPalette {
        scheme == .dark
            ? SettingsPalette(
                windowBackground: PanelPalette.hex(0x1F1F22), bar: PanelPalette.hex(0x2A2A2E),
                segmentOn: PanelPalette.rgba(255, 255, 255, 0.17), warning: PanelPalette.hex(0xFFAF4D),
                warningSoft: PanelPalette.rgba(255, 175, 77, 0.16))
            : SettingsPalette(
                windowBackground: PanelPalette.hex(0xFCFCFD), bar: PanelPalette.hex(0xF3F3F5),
                segmentOn: PanelPalette.hex(0xFFFFFF), warning: PanelPalette.hex(0xC46A00),
                warningSoft: PanelPalette.rgba(196, 106, 0, 0.12))
    }
}

/// 試作の設定シート（`base.css` の .set-*）の寸法
enum SettingsCSS {
    static let width: CGFloat = 640
    static let barHeight: CGFloat = 44
    static let title = CSSText(13, lineHeight: 1.45, weight: .semibold)
    static let lead = CSSText(12, lineHeight: 1.45)
    static let group = CSSText(11, lineHeight: 1.45, weight: .semibold)
    static let groupNote = CSSText(11, lineHeight: 1.45)
    static let label = CSSText(13, lineHeight: 1.45)
    static let detail = CSSText(11, lineHeight: 1.45)
    static let choice = CSSText(12, lineHeight: 1.45)
    static let message = CSSText(12, lineHeight: 1.45)
    static let foot = CSSText(11.5, lineHeight: 1.45)
}

/// 設定窓の中身。試作どおり 1 つの一覧に「動き」とキー割り当てのまとまりを並べる
struct SettingsView: View {
    @Bindable var model: SettingsModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = PanelPalette.of(scheme)
        let colors = SettingsPalette.of(scheme)
        VStack(spacing: 0) {
            SettingsTitleBar()
            Text(Self.lead)
                .css(SettingsCSS.lead)
                .foregroundStyle(palette.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 12, leading: 20, bottom: 8, trailing: 20))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !model.issues.isEmpty { SettingsIssuesView(issues: model.issues) }
                        ForEach(model.sections) { section in
                            SettingsGroupHeader(section: section)
                            ForEach(section.itemIDs, id: \.self) { id in
                                SettingsRow(model: model, id: id).id(id)
                            }
                        }
                    }
                    .padding(EdgeInsets(top: 0, leading: 12, bottom: 8, trailing: 12))
                }
                .scrollIndicators(.automatic)
                .onChange(of: model.scrollRequest) {
                    if let id = model.selectedID { proxy.scrollTo(id) }
                }
            }
            if let message = model.message {
                Text(message)
                    .css(SettingsCSS.message)
                    .foregroundStyle(palette.accentInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .overlay(alignment: .top) { Rectangle().fill(palette.sep).frame(height: 0.5) }
            }
            SettingsFooter(model: model)
        }
        .frame(width: SettingsCSS.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(colors.windowBackground)
        .environment(\.palette, palette)
    }

    static let lead =
        "呼び出しキーの動き・履歴の上限・アプリごとの扱いと、すべての操作のキーを変えられます。キーは選んで Enter を押し、新しいキーを押します。重なったキーは前の割り当てから外します。各項目の説明は、AI に設定を頼むときの一覧にもそのまま使います。"
}

/// 窓の上のバー（試作の .set-bar。信号機のボタンは本物の窓のものが重なる）
struct SettingsTitleBar: View {
    /// 題名（定型文の窓も同じバーを使う）
    var title = "Makurip 設定"
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(title)
            .css(SettingsCSS.title)
            .foregroundStyle(palette.text)
            .frame(maxWidth: .infinity)
            .frame(height: SettingsCSS.barHeight)
            .background(SettingsPalette.of(scheme).bar)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.sep).frame(height: 0.5) }
    }
}

struct SettingsGroupHeader: View {
    let section: SettingsModel.Section
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 2) {
            Text(section.title).css(SettingsCSS.group)
            if let note = section.note { Text(note).css(SettingsCSS.groupNote) }
        }
        .foregroundStyle(palette.text3)
        .padding(EdgeInsets(top: 10, leading: 8, bottom: 4, trailing: 8))
    }
}

/// 設定ファイルに読めない項目があったときの注記（試作に無い）
struct SettingsIssuesView: View {
    let issues: [SettingsError]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors = SettingsPalette.of(scheme)
        VStack(alignment: .leading, spacing: 2) {
            Text("設定ファイルに使えない値があったので、その項目は初期値で動いています。").css(SettingsCSS.detail)
            ForEach(Array(issues.prefix(4).enumerated()), id: \.offset) { _, issue in
                Text("\(issue.id): \(issue.message)").css(SettingsCSS.detail).lineLimit(2)
            }
        }
        .foregroundStyle(colors.warning)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .background(colors.warningSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.top, 8)
    }
}

/// 1 行（試作の .set-row）。左に名前と説明、右に切り替え・数・キー
struct SettingsRow: View {
    @Bindable var model: SettingsModel
    let id: String
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let item = model.item(id)
        let selected = model.selectedID == id
        let recording = selected && model.recording
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item?.label(in: model.settings) ?? id)
                    .css(SettingsCSS.label)
                    .foregroundStyle(palette.text)
                Text(item?.summary ?? "")
                    .css(SettingsCSS.detail)
                    .foregroundStyle(palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
                notes(item)
                if let item, Self.listsApps(item.kind) {
                    SettingsAppChips(model: model, id: id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let item { trailing(item, recording: recording) }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(minHeight: 46)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? palette.accentSoft : .clear)
        )
        .overlay {
            if recording {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.accent, lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if item?.keyAction != nil { model.startRecording(id) } else { model.select(id) }
        }
    }

    static func listsApps(_ kind: SettingItem.Kind) -> Bool {
        switch kind {
        case .appList, .appMap: true
        default: false
        }
    }

    @ViewBuilder
    private func notes(_ item: SettingItem?) -> some View {
        let colors = SettingsPalette.of(scheme)
        if let item {
            switch item.kind {
            case .choice:
                if let choice = model.currentChoice(id) {
                    Text("いま：\(choice.summary)")
                        .css(SettingsCSS.detail)
                        .foregroundStyle(palette.accentInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .toggle:
                if let note = model.environment.launchAtLoginNote(), model.environmentRevision >= 0 {
                    Text(note).css(SettingsCSS.detail).foregroundStyle(colors.warning)
                }
            case .keys(let action):
                if let warning = model.keyWarning(action) {
                    Text(warning)
                        .css(SettingsCSS.detail)
                        .foregroundStyle(colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func trailing(_ item: SettingItem, recording: Bool) -> some View {
        switch item.kind {
        case .choice(let choices):
            SettingsSegments(
                options: choices.map { ($0.value, $0.label) },
                selected: SettingsSchema.value(id, in: model.settings)?.stringValue
            ) { model.choose(id, $0) }
        case .toggle:
            SettingsSegments(
                options: [("false", "しない"), ("true", "する")],
                selected: SettingsSchema.value(id, in: model.settings)?.boolValue == true ? "true" : "false"
            ) { model.choose(id, $0) }
        case .integer, .number:
            SettingsNumberField(model: model, id: id)
        case .appList, .appMap:
            SettingsSmallButton(title: "追加…") { model.effects.pickApp(id) }
        case .keys(let action):
            SettingsKeys(model: model, action: action, recording: recording)
        }
    }
}

/// 選択肢の切り替え（試作の .set-choices）
struct SettingsSegments: View {
    let options: [(value: String, label: String)]
    let selected: String?
    let choose: (String) -> Void
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors = SettingsPalette.of(scheme)
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selected
                Text(option.label)
                    .font(.system(size: 12, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? palette.text : palette.text2)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(colors.segmentOn)
                                .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(palette.sep, lineWidth: 0.5))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { choose(option.value) }
            }
        }
        .padding(2)
        .background(palette.fill1, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize()
    }
}

/// 数（件数・容量・秒）。切り替えと同じ見た目で、−・値・＋ を並べる。値を押すと打ち込める
struct SettingsNumberField: View {
    @Bindable var model: SettingsModel
    let id: String
    @FocusState private var focused: Bool
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors = SettingsPalette.of(scheme)
        let editing = model.editingID == id
        HStack(spacing: 0) {
            stepButton("minus") {
                model.select(id)
                model.step(by: -1)
            }
            Group {
                if editing {
                    HStack(spacing: 4) {
                        TextField("", text: $model.editText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12).monospacedDigit())
                            .multilineTextAlignment(.trailing)
                            .frame(width: 52)
                            .focused($focused)
                            .onSubmit { model.commitEditing() }
                            .onAppear { focused = true }
                        Text(model.unit(id)).font(.system(size: 12)).foregroundStyle(palette.text2)
                    }
                } else {
                    Text(model.valueText(id))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(palette.text)
                        .frame(minWidth: 64)
                        .contentShape(Rectangle())
                        .onTapGesture { model.beginEditing(id) }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(colors.segmentOn)
                    .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(editing ? palette.accent : palette.sep, lineWidth: editing ? 1 : 0.5))
            )
            stepButton("plus") {
                model.select(id)
                model.step(by: 1)
            }
        }
        .padding(2)
        .background(palette.fill1, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize()
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(palette.text2)
            .frame(width: 26, height: 24)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

/// アプリの札（記録しないアプリ・確定まで貼らないアプリ）。× で外す
struct SettingsAppChips: View {
    @Bindable var model: SettingsModel
    let id: String
    @Environment(\.palette) private var palette

    var body: some View {
        let entries = model.appEntries(id)
        Group {
            if entries.isEmpty {
                Text("なし").css(SettingsCSS.detail).foregroundStyle(palette.text3)
            } else {
                FlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(entries) { entry in
                        HStack(spacing: 4) {
                            Text(entry.name).lineLimit(1)
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(palette.text3)
                                .frame(width: 12, height: 12)
                                .contentShape(Rectangle())
                                .onTapGesture { model.removeApp(id, bundleID: entry.bundleID) }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(palette.text2)
                        .padding(.leading, 7)
                        .padding(.trailing, 4)
                        .frame(height: 20)
                        .background(palette.fill1, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(
                                palette.kbLine, lineWidth: 0.5)
                        )
                        .help(entry.bundleID)
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}

/// 小さいボタン（試作の .set-reset と同じ形）
struct SettingsSmallButton: View {
    let title: String
    var height: CGFloat = 24
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(palette.text)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(palette.fill2, in: Capsule())
            .contentShape(Capsule())
            .onTapGesture(perform: action)
            .fixedSize()
    }
}

/// キーの行の右（試作の .set-k と .rec-pill）
struct SettingsKeys: View {
    @Bindable var model: SettingsModel
    let action: KeyAction
    let recording: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            if recording {
                Text(action.usesDigits ? "修飾キー＋数字を押す…" : "新しいキーを押す…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(palette.accent, in: Capsule())
                    .modifier(Pulse())
            } else {
                let combos = model.combos(action)
                let warn = !model.conflicts(action).isEmpty
                if combos.isEmpty {
                    KeyChip(modifiers: "", key: "未設定", style: .none)
                } else {
                    ForEach(Array(combos.enumerated()), id: \.offset) { _, combo in
                        KeyChip(combo, style: warn ? .warning : .normal)
                    }
                }
            }
        }
        .fixedSize()
    }
}

/// 記録中の札の明滅（試作の pulse。1.2 秒で 65% まで薄くなる）
struct Pulse: ViewModifier {
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.65 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// 下の段（試作の .set-foot）。キーのヒントと「すべて初期値に戻す」
struct SettingsFooter: View {
    @Bindable var model: SettingsModel
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 12) {
                Hint(combos: [KeyCombo(.code(KeyCodes.upArrow)), KeyCombo(.code(KeyCodes.downArrow))], label: "選ぶ")
                Hint(combos: [KeyCombo(.code(KeyCodes.returnKey))], label: "変更")
                Hint(
                    combos: [KeyCombo(.code(KeyCodes.leftArrow)), KeyCombo(.code(KeyCodes.rightArrow))], label: "選択肢")
                Hint(combos: [KeyCombo(.code(KeyCodes.delete))], label: "初期値")
                Hint(combos: [KeyCombo(.code(KeyCodes.escape))], label: "閉じる")
            }
            .font(.system(size: 11.5))
            Spacer(minLength: 0)
            SettingsSmallButton(title: "すべて初期値に戻す", height: 26) { model.resetAll() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(palette.sep).frame(height: 0.5) }
    }
}

/// 札を左から詰めて、入らなければ次の行へ送る
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(indices: [], y: current.y + current.height + lineSpacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
