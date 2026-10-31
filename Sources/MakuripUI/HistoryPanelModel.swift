import Foundation
import MakuripCore
import Observation

/// 案 B のパネルの状態と操作。キー入力はすべて `handle(_:isComposing:)` を通り、キーマップから操作を引く。
///
/// 画面（SwiftUI）と窓（`PanelController`）はこの状態を見るだけにして、操作の結果はテストで確かめられるようにしてある。
/// 窓の外への作用（貼り付け・閉じる・ページを開く）は `effects` に渡す。
@MainActor
@Observable
final class HistoryPanelModel {
    struct Effects {
        var paste: (UUID, PasteMode) -> Void = { _, _ in }
        var close: () -> Void = {}
        var openURL: (URL) -> Void = { _ in }
        /// ⌘Y のプレビューを出す・閉じる（窓を足したり外したりするのは PanelController）
        var previewChanged: (Bool) -> Void = { _ in }
        /// 設定画面を開く（一覧を閉じてから）
        var openSettings: () -> Void = {}
        /// 定型文を貼る（置き換えは本体が行う）
        var pasteSnippet: (UUID, PasteMode) -> Void = { _, _ in }
        /// 定型文の窓を開く（一覧を閉じてから）
        var editSnippet: (SnippetEditRequest) -> Void = { _ in }
    }

    /// 一覧に読み込む最大件数。ストアの件数上限（既定 1000）より大きくして全件を読む
    static let loadLimit = 100_000

    /// 設定で付け替えられる（開いている間に変わっても、次のキーから新しい割り当てで引く）
    var keymap: Keymap
    @ObservationIgnored weak var actions: HistoryActions?
    @ObservationIgnored var effects = Effects()
    @ObservationIgnored var clock: () -> Date = Date.init

    // MARK: 状態

    private(set) var allItems: [ClipItem] = []
    /// 絞り込んだ結果（表示している順）
    private(set) var items: [ClipItem] = []
    /// 一覧の行（日付の見出しとカード）。絞り込みのたびに作る（描画のたびに数千件の日付を計算しないように）
    private(set) var rows: [PanelRow] = []
    private(set) var kindCounts: [ClipKind?: Int] = [nil: 0]
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            searchQuery = SearchText.parse(query)
            refresh(keepSelection: false)
        }
    }
    private(set) var searchQuery = SearchQuery.empty
    private(set) var kind: ClipKind?
    private(set) var method = CopyMethodFilter.all
    /// コピー元アプリ（`HistoryFilter.appKey(of:)`）
    private(set) var app: String?
    private(set) var pinnedOnly = false
    /// 定型文の一覧を出しているか（⌘S。試作の scope = snippets）
    private(set) var showsSnippets = false
    private(set) var allSnippets: [Snippet] = []
    /// 検索で絞った定型文（表示している順）
    private(set) var snippetItems: [Snippet] = []
    private(set) var selectedIndex = 0
    /// ⌘Y の大きいプレビュー
    private(set) var isPreviewOpen = false {
        didSet {
            if isPreviewOpen != oldValue { effects.previewChanged(isPreviewOpen) }
        }
    }
    /// 一覧を開いた時刻（相対時刻の基準。開いている間は動かさない）
    private(set) var now = Date()
    /// ⌘ を押している間、カードの番号（⌘1〜9）を強調する
    var quickModifierHeld = false
    /// 「隠した内容を表示」のキー（既定 ⌥）を押している間だけ、秘密の中身を出す
    var revealHeld = false
    /// ⌘Y のプレビューの「押している間だけ表示」を押している間
    var revealPressed = false
    var isRevealing: Bool { revealHeld || revealPressed }
    /// 0 件で貼ろうとしたときなどにパネルを揺らす（値が変わるたびに 1 回）
    private(set) var shakeCount = 0
    /// 検索欄へフォーカスを戻す合図（値が変わるたびに）
    private(set) var focusRequest = 0

    // ⌘E のアプリ選択
    private(set) var isPickerOpen = false
    private(set) var pickerOptions: [AppOption] = []
    var pickerQuery = "" {
        didSet {
            guard pickerQuery != oldValue else { return }
            pickerSelection = 0
        }
    }
    private(set) var pickerSelection = 0

    @ObservationIgnored private var haystacks: [UUID: (hash: String, text: String)] = [:]
    @ObservationIgnored private var snippetHaystacks: [UUID: (snippet: Snippet, text: String)] = [:]
    @ObservationIgnored private var snippetMasks: [UUID: (snippet: Snippet, masked: Snippet?)] = [:]
    @ObservationIgnored private var warmTask: Task<Void, Never>?

    init(actions: HistoryActions?, keymap: Keymap = .default) {
        self.actions = actions
        self.keymap = keymap
    }

    var filter: HistoryFilter {
        HistoryFilter(kind: kind, method: method, app: app, pinnedOnly: pinnedOnly, query: searchQuery)
    }

    /// 選んでいる履歴（定型文の一覧では nil）
    var selected: ClipItem? {
        guard !showsSnippets else { return nil }
        return items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    /// 選んでいる定型文（履歴の一覧では nil）
    var selectedSnippet: Snippet? {
        guard showsSnippets else { return nil }
        return snippetItems.indices.contains(selectedIndex) ? snippetItems[selectedIndex] : nil
    }

    /// {{日付}} の書き方（⌘Y の説明に使う）
    var snippetDateFormat: SnippetDateFormat { actions?.snippetDateFormat() ?? .default }

    /// いま出している行の数（履歴か定型文）
    var rowCount: Int { showsSnippets ? snippetItems.count : items.count }

    /// 選んでいるアプリの表示名
    var appName: String? {
        guard let app else { return nil }
        return allItems.first { HistoryFilter.appKey(of: $0.source) == app }?.source?.name ?? app
    }

    var appBundleID: String? {
        guard let app else { return nil }
        return allItems.first { HistoryFilter.appKey(of: $0.source) == app }?.source?.bundleID
    }

    var shownPickerOptions: [AppOption] {
        let query = SearchText.parse(pickerQuery)
        return query.isEmpty ? pickerOptions : pickerOptions.filter { $0.matches(query) }
    }

    // MARK: 開く・読み直す

    /// 開くたびに絞り込みを外し、検索欄を空にして最新を選ぶ（試作と同じ）。
    /// 候補窓から広げたときは、候補窓で選んでいた項目を選んだ状態で開く（`itemID`）
    func open(selecting itemID: UUID? = nil) {
        query = ""
        searchQuery = .empty
        kind = nil
        method = .all
        app = nil
        pinnedOnly = false
        showsSnippets = false
        isPreviewOpen = false
        isPickerOpen = false
        pickerQuery = ""
        revealHeld = false
        revealPressed = false
        now = clock()
        loadSnippets()
        reload(keepSelection: false)
        if let itemID, let index = items.firstIndex(where: { $0.id == itemID }) { selectedIndex = index }
        focusRequest += 1
    }

    /// 履歴を読み直す（取り込み・ピン留め・削除のあと）。選んでいた項目はなるべく選んだままにする。
    ///
    /// 検索用の正規化（`HistoryFilter.haystack`）は数千件だと数百 ms かかるので、ここでは作らない。
    /// 検索語が入ったときに足りない分だけその場で作り、開いた後に裏で温めておく（内容のハッシュが同じなら使い回す）
    func reload(keepSelection: Bool = true) {
        let loaded = actions?.historyItems(limit: Self.loadLimit) ?? []
        allItems = loaded
        let alive = Dictionary(loaded.map { ($0.id, $0.contentHash) }, uniquingKeysWith: { first, _ in first })
        haystacks = haystacks.filter { alive[$0.key] == $0.value.hash }
        refresh(keepSelection: keepSelection)
        warmHaystacks()
    }

    func haystack(_ item: ClipItem) -> String {
        if let cached = haystacks[item.id], cached.hash == item.contentHash { return cached.text }
        let text = HistoryFilter.haystack(for: item)
        haystacks[item.id] = (item.contentHash, text)
        return text
    }

    /// まだ正規化していない項目を、メインスレッドの外でまとめて正規化しておく
    private func warmHaystacks() {
        warmTask?.cancel()
        let missing = allItems.filter { haystacks[$0.id]?.hash != $0.contentHash }
        guard !missing.isEmpty else { return }
        warmTask = Task { [weak self] in
            let computed = await Task.detached(priority: .utility) {
                missing.map { ($0.id, $0.contentHash, HistoryFilter.haystack(for: $0)) }
            }.value
            guard !Task.isCancelled, let self else { return }
            for (id, hash, text) in computed where self.haystacks[id] == nil {
                self.haystacks[id] = (hash, text)
            }
        }
    }

    private func refresh(keepSelection: Bool) {
        let previous = showsSnippets ? selectedSnippet?.id : selected?.id
        let previousIndex = selectedIndex
        let filter = self.filter
        items = filter.apply(to: allItems, haystack: haystack)
        kindCounts = filter.kindCounts(in: allItems, haystack: haystack)
        rows = PanelRow.make(items, now: now)
        snippetItems =
            searchQuery.isEmpty
            ? allSnippets : allSnippets.filter { searchQuery.matches(normalized: snippetHaystack($0)) }
        let ids = showsSnippets ? snippetItems.map(\.id) : items.map(\.id)
        if keepSelection, let previous, let index = ids.firstIndex(of: previous) {
            selectedIndex = index
        } else if keepSelection {
            selectedIndex = min(previousIndex, max(0, ids.count - 1))
        } else {
            selectedIndex = 0
        }
    }

    // MARK: 定型文

    /// 定型文を読み直す（開いたとき・定型文の窓やファイルで変わったとき）
    func reloadSnippets() {
        loadSnippets()
        refresh(keepSelection: true)
    }

    private func loadSnippets() {
        allSnippets = actions?.snippets() ?? []
        let alive = Set(allSnippets.map(\.id))
        snippetHaystacks = snippetHaystacks.filter { alive.contains($0.key) }
        snippetMasks = snippetMasks.filter { alive.contains($0.key) }
    }

    /// 定型文の検索用の文字列（中身が変わったら作り直す。数百件でも打鍵のたびに正規化しないように）。
    /// 秘密っぽい定型文は伏せ字の写しから作る（履歴の秘密と同じく、本当の値では引けない。#29 L3）
    func snippetHaystack(_ snippet: Snippet) -> String {
        if let cached = snippetHaystacks[snippet.id], cached.snippet == snippet { return cached.text }
        let text = maskedSnippet(snippet) == nil ? snippet.searchHaystack : snippet.maskedSearchHaystack
        snippetHaystacks[snippet.id] = (snippet, text)
        return text
    }

    /// 秘密っぽい定型文の伏せ字の写し（秘密でなければ nil）。判定は中身が変わったときだけやり直す
    func maskedSnippet(_ snippet: Snippet) -> Snippet? {
        if let cached = snippetMasks[snippet.id], cached.snippet == snippet { return cached.masked }
        let masked = snippet.isSecretLikely ? snippet.masked : nil
        snippetMasks[snippet.id] = (snippet, masked)
        return masked
    }

    /// カード・⌘Y に出す定型文。秘密っぽいものは伏せ字で、表示のキーを押している間だけ本当の値（#29 L3）
    func shownSnippet(_ snippet: Snippet) -> Snippet {
        guard !isRevealing, let masked = maskedSnippet(snippet) else { return snippet }
        return masked
    }

    /// ⌘S: 定型文の一覧と履歴を切り替える。ピン留めだけの表示は外す（試作の scope は 1 つ）
    func toggleSnippets() {
        showsSnippets.toggle()
        if showsSnippets { pinnedOnly = false }
        refresh(keepSelection: false)
    }

    /// 定型文の窓を開く。定型文の一覧では選んだものを編集、履歴の一覧では選んだ項目から新しく作る。
    /// 秘密っぽい項目からは作らず、パネルを揺らす（定型文の窓は本文を伏せずに出し、定型文は伏せ字にも自動消去にもならない。#25）
    func editSnippet() {
        if showsSnippets {
            effects.editSnippet(selectedSnippet.map { .edit($0.id) } ?? .new(body: ""))
        } else if selected?.isSecretLikely == true {
            shakeCount += 1
        } else {
            effects.editSnippet(selected.map { .fromHistory($0.id) } ?? .new(body: ""))
        }
    }

    // MARK: キー

    /// 押されたキーを処理したら true（false のキーは検索欄へ流す）。
    /// 日本語入力の変換中（`isComposing`）は何も横取りしない（確定の Enter や候補選びの ↑↓ を奪わないため）。
    /// 表示のキー（⌥）を押したままでも、ほかの操作のキーは効く（⌥ で秘密を見ながら ↩ で貼る。#28）
    func handle(_ press: KeyStroke, isComposing: Bool = false) -> Bool {
        if isComposing { return false }
        guard let (action, digit) = keymap.action(for: press, scope: .panel, ignoringHeld: .reveal) else {
            return false
        }
        if isPickerOpen { return handlePicker(action) }
        perform(action, digit: digit)
        return true
    }

    func perform(_ action: KeyAction, digit: Int? = nil) {
        // 定型文の一覧では、絞り込み・ピン留め・削除は効かない（試作と同じ。コピー元のページはないので揺らす）
        if showsSnippets, [.kindNext, .kindPrevious, .cycleMethod, .chooseApp, .togglePin, .delete].contains(action) {
            return
        }
        switch action {
        case .openHistory, .openList, .candidateUp, .candidateDown, .candidateCommit, .candidateCancel,
            .candidateExpand:
            break  // パネルの範囲のキーではない（全体のキーと候補窓のキー）
        case .close:
            if !query.isEmpty {
                query = ""
            } else {
                effects.close()
            }
        case .previous:
            move(by: -1)
        case .next:
            move(by: 1)
        case .paste:
            pasteSelected(.normal)
        case .pastePlain:
            pasteSelected(.plainText)
        case .copyOnly:
            pasteSelected(.copyOnly)
        case .quickPaste:
            guard let digit, digit - 1 < rowCount else { return }
            selectedIndex = digit - 1
            pasteSelected(.normal)
        case .kindNext:
            stepKind(by: 1)
        case .kindPrevious:
            stepKind(by: -1)
        case .cycleMethod:
            setMethod(method.next)
        case .chooseApp:
            openPicker()
        case .pinnedOnly:
            togglePinnedOnly()
        case .snippets:
            toggleSnippets()
        case .togglePin:
            togglePin()
        case .preview:
            isPreviewOpen.toggle()
        case .reveal:
            break  // 押している間だけ効く（修飾キーの変化で PanelController が `revealHeld` を変える）
        case .openSource:
            openSource()
        case .delete:
            deleteSelected()
        case .settings:
            effects.openSettings()
        case .editSnippet:
            editSnippet()
        }
    }

    // MARK: 操作（マウスからも呼ぶ）

    func select(_ index: Int) {
        guard rowCount > 0 else { return }
        selectedIndex = min(max(0, index), rowCount - 1)
    }

    func move(by delta: Int) {
        select(selectedIndex + delta)
    }

    func pasteSelected(_ mode: PasteMode) {
        if showsSnippets {
            guard let snippet = selectedSnippet else {
                shakeCount += 1
                return
            }
            effects.pasteSnippet(snippet.id, mode)
            return
        }
        guard let item = selected else {
            shakeCount += 1
            return
        }
        effects.paste(item.id, mode)
    }

    func setKind(_ kind: ClipKind?) {
        guard !showsSnippets else { return }
        self.kind = kind
        refresh(keepSelection: false)
    }

    func stepKind(by delta: Int) {
        let tabs = HistoryFilter.kindTabs
        let index = tabs.firstIndex(of: kind) ?? 0
        setKind(tabs[(index + delta + tabs.count) % tabs.count])
    }

    func setMethod(_ method: CopyMethodFilter) {
        guard !showsSnippets else { return }
        self.method = method
        refresh(keepSelection: false)
    }

    func setApp(_ app: String?) {
        self.app = app
        refresh(keepSelection: false)
    }

    /// 定型文の一覧で押したら、履歴のピン留めだけの表示へ移る（試作の setScope('pinned')）
    func togglePinnedOnly() {
        if showsSnippets {
            showsSnippets = false
            pinnedOnly = true
        } else {
            pinnedOnly.toggle()
        }
        refresh(keepSelection: false)
    }

    func clearQuery() {
        query = ""
        focusRequest += 1
    }

    func togglePin() {
        guard let item = selected else { return }
        actions?.setPinned(!item.isPinned, itemID: item.id)
        reload()
    }

    func deleteSelected() {
        guard let item = selected else { return }
        actions?.delete(itemID: item.id)
        reload()
    }

    func openSource() {
        guard let item = selected else {
            if showsSnippets { shakeCount += 1 }
            return
        }
        // 秘密の URL（`?token=…` のリンク）の一覧用の平文は伏せ字なので使わない（コピー元のページだけを開く）
        let text =
            item.kind == .url && !item.isSecretLikely
            ? item.previewText?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        guard let url = (item.sourceURL ?? text).flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true
        else {
            shakeCount += 1
            return
        }
        effects.openURL(url)
    }

    func setPreviewOpen(_ open: Bool) {
        isPreviewOpen = open
    }

    // MARK: ⌘E のアプリ選択

    func openPicker() {
        guard !showsSnippets else { return }
        pickerOptions = filter.appOptions(in: allItems, haystack: haystack)
        pickerQuery = ""
        pickerSelection = max(0, pickerOptions.firstIndex { $0.key == app } ?? 0)
        isPickerOpen = true
    }

    func closePicker() {
        isPickerOpen = false
        focusRequest += 1
    }

    func choosePickerOption(at index: Int? = nil) {
        let shown = shownPickerOptions
        let index = index ?? pickerSelection
        closePicker()
        guard shown.indices.contains(index) else { return }
        setApp(shown[index].key)
    }

    /// アプリ選択が開いている間のキー（↑↓ で選ぶ・Enter で決める・esc と ⌘E で閉じる）。
    /// ほかの操作のキーは何もせずに食べる（⇥ でフォーカスが外へ逃げたり、裏の一覧が動いたりしないように）
    private func handlePicker(_ action: KeyAction) -> Bool {
        switch action {
        case .close, .chooseApp:
            closePicker()
        case .previous:
            pickerSelection = max(0, pickerSelection - 1)
        case .next:
            pickerSelection = min(max(0, shownPickerOptions.count - 1), pickerSelection + 1)
        case .paste:
            choosePickerOption()
        default:
            break
        }
        return true
    }

    // MARK: 検証用

    var debugState: [String: String] {
        [
            "query": query,
            "rowCount": String(rowCount),
            "showsSnippets": String(showsSnippets),
            "snippetCount": String(allSnippets.count),
            "loadedCount": String(allItems.count),
            "selectedIndex": String(selectedIndex),
            "selectedKind": selected?.kind.rawValue ?? "",
            "kindFilter": kind?.rawValue ?? "all",
            "methodFilter": method.rawValue,
            "appFilter": app ?? "",
            "pinnedOnly": String(pinnedOnly),
            "previewOpen": String(isPreviewOpen),
            "pickerOpen": String(isPickerOpen),
            "revealing": String(isRevealing),
            "selectedSecret": String(selected?.isSecretLikely ?? false),
        ]
    }
}

/// 一覧の 1 行（日付の見出しか、カード）
enum PanelRow: Identifiable, Hashable {
    case header(DisplayText.DayGroup)
    case card(index: Int, item: ClipItem)

    var id: String {
        switch self {
        case .header(let group): "group-\(group.rawValue)"
        case .card(_, let item): item.id.uuidString
        }
    }

    static func make(_ items: [ClipItem], now: Date, calendar: Calendar = .current) -> [PanelRow] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        var rows: [PanelRow] = []
        rows.reserveCapacity(items.count + 3)
        var current: DisplayText.DayGroup?
        for (index, item) in items.enumerated() {
            let group: DisplayText.DayGroup =
                item.lastUsedAt >= today ? .today : item.lastUsedAt >= yesterday ? .yesterday : .older
            if group != current {
                rows.append(.header(group))
                current = group
            }
            rows.append(.card(index: index, item: item))
        }
        return rows
    }
}
