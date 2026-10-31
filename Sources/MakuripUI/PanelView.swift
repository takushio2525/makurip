import MakuripCore
import SwiftUI

/// 案 B のパネル（372 × 528）。試作の `panel-b.js` / `panel-b.css` の並びと寸法どおり
struct HistoryPanelView: View {
    @Bindable var model: HistoryPanelModel
    let loader: ClipContentLoader
    @Environment(\.colorScheme) private var scheme

    static let size = CGSize(width: 372, height: 528)
    /// カードの一覧の左右の余白（試作の .pb-list の padding）
    static let listInset: CGFloat = 10
    /// カードに渡る幅（パネルの幅から左右の余白を引いたもの）。カードはこの幅を超えない（#16）
    static var cardWidth: CGFloat { size.width - listInset * 2 }

    var body: some View {
        PanelContent(model: model, loader: loader)
            .environment(\.palette, .of(scheme))
    }
}

private struct PanelContent: View {
    @Bindable var model: HistoryPanelModel
    let loader: ClipContentLoader
    @Environment(\.palette) private var palette
    @FocusState private var focus: Field?
    @State private var shake: CGFloat = 0

    enum Field: Hashable {
        case search
        case picker
    }

    var body: some View {
        VStack(spacing: 0) {
            KindTabs(model: model)
            CaptionRow(model: model)
            SearchRow(model: model, focus: $focus)
            FilterRow(model: model)
            CardList(model: model, loader: loader)
            FooterHints(model: model)
        }
        .frame(width: HistoryPanelView.size.width, height: HistoryPanelView.size.height)
        .overlay(alignment: .topLeading) {
            if model.isPickerOpen {
                ZStack(alignment: .topLeading) {
                    // 外をクリックしたら閉じる
                    Color.black.opacity(0.001).onTapGesture { model.closePicker() }
                    AppPickerView(model: model, focus: $focus)
                        .offset(x: 84, y: 142)
                }
            }
        }
        .foregroundStyle(palette.text)
        .glassSurface()
        .modifier(ShakeEffect(animatableData: shake))
        .onAppear { focus = .search }
        .onChange(of: model.focusRequest) { _, _ in focus = .search }
        .onChange(of: model.isPickerOpen) { _, open in focus = open ? .picker : .search }
        .onChange(of: model.shakeCount) { _, _ in
            shake = 0
            withAnimation(.linear(duration: 0.3)) { shake = 1 }
        }
    }
}

/// 上段のタブ（種類 9 つ｜ピン留め）
private struct KindTabs: View {
    let model: HistoryPanelModel
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 1) {
            ForEach(HistoryFilter.kindTabs, id: \.self) { kind in
                let on = model.kind == kind
                let color = palette.kind(kind)
                TabButton(
                    symbol: PanelSymbols.kind(kind),
                    iconColor: kind == nil ? (on ? palette.text : palette.text2) : color,
                    background: on ? (kind == nil ? palette.fill2 : color.opacity(0.17)) : .clear,
                    border: on ? (kind == nil ? palette.sep : color.opacity(0.4)) : .clear,
                    help: "\(KindNames.label(kind))（\(model.kindCounts[kind] ?? 0) 件）"
                ) { model.setKind(kind) }
            }
            Rectangle().fill(palette.sep).frame(width: 0.5, height: 18).padding(.horizontal, 5)
            let pinnedHint = model.keymap.primary(.pinnedOnly)?.displayString ?? ""
            TabButton(
                symbol: model.pinnedOnly ? "pin.fill" : "pin", iconColor: model.pinnedOnly ? .white : palette.text2,
                background: model.pinnedOnly ? palette.accent : .clear, border: .clear,
                help: "ピン留め（\(pinnedHint)）"
            ) { model.togglePinnedOnly() }
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .padding(.horizontal, 8)
    }
}

private struct TabButton: View {
    let symbol: String
    let iconColor: Color
    let background: Color
    let border: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5))
                .environment(\.locale, Locale(identifier: "en_US"))
                .foregroundStyle(iconColor)
                .frame(width: 29, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(border, lineWidth: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 選んでいる種類の名前と件数（すべて 27 件　⇥ 次の種類）
private struct CaptionRow: View {
    let model: HistoryPanelModel
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            if model.pinnedOnly { Text("ピン留め · ") }
            Text(KindNames.label(model.kind))
                .fontWeight(.semibold)
                .foregroundStyle(palette.kind(model.kind))
            Text(verbatim: "\(model.items.count) 件")
                .monospacedDigit()
                .foregroundStyle(palette.text3)
            Spacer(minLength: 0)
            if let combo = model.keymap.primary(.kindNext) {
                KeyChip(combo)
                Text("次の種類").foregroundStyle(palette.text3)
            }
        }
        .font(.system(size: 12))
        .frame(height: 28)
        .padding(.horizontal, 14)
    }
}

private struct SearchRow: View {
    @Bindable var model: HistoryPanelModel
    var focus: FocusState<PanelContent.Field?>.Binding
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 13))
            TextField(
                "履歴を検索", text: $model.query,
                prompt: Text("検索（ローマ字・かなでも）").foregroundStyle(palette.text3)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(palette.text)
            .focused(focus, equals: .search)
            if !model.query.isEmpty {
                Button {
                    model.clearQuery()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13.5))
                }
                .buttonStyle(.plain)
                .help("検索を消す")
            }
        }
        .foregroundStyle(palette.text3)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.fill1))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.sep, lineWidth: 0.5))
        .padding(.horizontal, 10)
    }
}

/// コピー方法（⌘K）とアプリ（⌘E）の絞り込み
private struct FilterRow: View {
    let model: HistoryPanelModel

    var body: some View {
        HStack(spacing: 6) {
            FilterButton(
                on: model.method != .all, combo: model.keymap.primary(.cycleMethod), help: "コピー方法で絞り込む",
                action: { model.setMethod(model.method.next) }
            ) {
                Image(systemName: PanelSymbols.methodFilter(model.method)).font(.system(size: 11.5))
                Text(DisplayText.methodFilter(model.method))
            }
            FilterButton(
                on: model.app != nil, combo: model.keymap.primary(.chooseApp), help: "コピー元のアプリで絞り込む",
                action: { model.openPicker() }
            ) {
                if let app = model.app {
                    AppIconView(bundleID: model.appBundleID, name: model.appName ?? app, size: 14)
                    Text(model.appName ?? app)
                } else {
                    Image(systemName: "square.grid.2x2").font(.system(size: 11.5))
                    Text("アプリ：すべて")
                }
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

private struct FilterButton<Label: View>: View {
    let on: Bool
    let combo: KeyCombo?
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                HStack(spacing: 5) { label() }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let combo { KeyChip(combo, style: .small) }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(on ? palette.accentInk : palette.text2)
            .padding(.leading, 8)
            .padding(.trailing, 5)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? palette.accentSoft : .clear))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(on ? palette.accent.opacity(0.4) : palette.sep, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .frame(maxWidth: .infinity)
    }
}

/// カードの一覧。見えている分だけ作る（LazyVStack）。選択が動いたら見える位置まで送る
private struct CardList: View {
    let model: HistoryPanelModel
    let loader: ClipContentLoader
    @Environment(\.palette) private var palette

    var body: some View {
        if model.items.isEmpty {
            EmptyStateView(model: model)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.rows) { row in
                            switch row {
                            case .header(let group):
                                Text(group.rawValue)
                                    .css(CSS.group)
                                    .foregroundStyle(palette.text3)
                                    .padding(EdgeInsets(top: 6, leading: 4, bottom: 0, trailing: 4))
                                    .id(row.id)
                            case .card(let index, let item):
                                CardView(
                                    item: item, index: index, isSelected: index == model.selectedIndex,
                                    query: model.searchQuery, now: model.now, quickHeld: model.quickModifierHeld,
                                    quickCombo: model.keymap.primary(.quickPaste), loader: loader
                                )
                                .id(row.id)
                                .onTapGesture(count: 2) {
                                    model.select(index)
                                    model.pasteSelected(.normal)
                                }
                                .onTapGesture { model.select(index) }
                            }
                        }
                    }
                    .padding(
                        EdgeInsets(
                            top: 4, leading: HistoryPanelView.listInset, bottom: 10,
                            trailing: HistoryPanelView.listInset))
                }
                .scrollIndicators(.automatic)
                .onAppear {
                    let index = model.selectedIndex
                    DispatchQueue.main.async { scroll(proxy, to: index) }
                }
                .onChange(of: model.selectedIndex) { _, index in scroll(proxy, to: index) }
                .onChange(of: model.rows.first?.id) { _, _ in scroll(proxy, to: model.selectedIndex) }
            }
        }
    }

    /// 先頭を選んだら見出しごといちばん上へ。それ以外は見える位置まで最小限だけ送る（試作の scrollIntoView nearest）
    private func scroll(_ proxy: ScrollViewProxy, to index: Int) {
        if index == 0, let first = model.rows.first {
            proxy.scrollTo(first.id, anchor: .top)
        } else if model.items.indices.contains(index) {
            proxy.scrollTo(model.items[index].id.uuidString)
        }
    }
}

/// 下段のキーのヒント（↑↓ 選ぶ　↩ 貼る　⌘1–9 すぐ貼る　⌘Y 拡大）と、右端の設定の歯車（試作の .gear）
private struct FooterHints: View {
    let model: HistoryPanelModel
    @Environment(\.palette) private var palette

    var body: some View {
        let keymap = model.keymap
        HStack(spacing: 12) {
            Hint(combos: [keymap.primary(.previous), keymap.primary(.next)].compactMap { $0 }, label: "選ぶ")
            Hint(combos: [keymap.primary(.paste)].compactMap { $0 }, label: "貼る")
            Hint(combos: [keymap.primary(.quickPaste)].compactMap { $0 }, label: "すぐ貼る")
            Hint(combos: [keymap.primary(.preview)].compactMap { $0 }, label: "拡大")
            Spacer(minLength: 0)
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.text2)
                .frame(width: 26, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onTapGesture { model.effects.openSettings() }
                .help("キー設定（\(keymap.primary(.settings)?.displayString ?? "未設定")）")
        }
        .font(.system(size: 11))
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 36)
        .overlay(alignment: .top) { Rectangle().fill(palette.sep).frame(height: 0.5) }
    }
}

/// ⌘E のアプリ選択（試作の .mk-pop。ひらがな・ローマ字でアプリ名を探せる）
private struct AppPickerView: View {
    @Bindable var model: HistoryPanelModel
    var focus: FocusState<PanelContent.Field?>.Binding
    @Environment(\.palette) private var palette

    var body: some View {
        let shown = model.shownPickerOptions
        let query = SearchText.parse(model.pickerQuery)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11.5)).foregroundStyle(palette.text3)
                TextField(
                    "アプリを検索", text: $model.pickerQuery,
                    prompt: Text("アプリ名で絞る（ローマ字でも）").foregroundStyle(palette.text3)
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(focus, equals: .picker)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.fill1))
            .padding(.bottom, 4)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        if shown.isEmpty {
                            Text("該当するアプリはありません")
                                .foregroundStyle(palette.text3)
                                .padding(.vertical, 14)
                        }
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, option in
                            PickerRow(
                                option: option, query: query, selected: index == model.pickerSelection,
                                current: option.key == model.app
                            )
                            .id(option.id)
                            .onTapGesture { model.choosePickerOption(at: index) }
                        }
                    }
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: model.pickerSelection) { _, index in
                    if shown.indices.contains(index) { proxy.scrollTo(shown[index].id) }
                }
            }
            HStack(spacing: 12) {
                Hint(
                    combos: [model.keymap.primary(.previous), model.keymap.primary(.next)].compactMap { $0 },
                    label: "選ぶ")
                Hint(combos: [model.keymap.primary(.paste)].compactMap { $0 }, label: "決定")
                Hint(combos: [model.keymap.primary(.close)].compactMap { $0 }, label: "閉じる")
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .padding(EdgeInsets(top: 8, leading: 6, bottom: 2, trailing: 6))
            .overlay(alignment: .top) { Rectangle().fill(palette.sep).frame(height: 0.5) }
            .padding(.top, 4)
        }
        .padding(6)
        .frame(width: 280)
        .glassSurface(cornerRadius: 14, withinWindow: true)
        .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
    }
}

private struct PickerRow: View {
    let option: AppOption
    let query: SearchQuery
    let selected: Bool
    let current: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            if option.key == nil {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 10.5))
                    .foregroundStyle(selected ? .white : palette.text2)
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 5).fill(selected ? Color.white.opacity(0.25) : palette.fill2))
            } else {
                AppIconView(bundleID: option.bundleID, name: option.name, size: 18)
            }
            Text(Highlight.attributed(option.name, query: query, mark: palette.mark))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: "\(option.count)")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(selected ? Color.white.opacity(0.8) : palette.text3)
            if current {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(selected ? .white : palette.text)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? palette.accent : .clear))
        .contentShape(Rectangle())
    }
}
