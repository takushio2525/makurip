import Foundation

/// 一覧 UI と本体のあいだの約束。`MakuripUI` を丸ごと差し替えるとき、新しい UI はこの 2 つのプロトコルだけを
/// 相手にすればよい（本体のコードは変えなくてよい）。
///
/// 本体（`Makurip` ターゲット）が `HistoryActions` を実装して UI に渡し、UI は `HistoryPresenting` を実装する。
@MainActor
public protocol HistoryPresenting: AnyObject {
    var isVisible: Bool { get }
    /// 一覧を開く（⌃⌘V・メニューから）
    func show()
    /// 項目を選んだ状態で開く（候補窓から広げたとき）。実装しなければ `show()`
    func show(selecting itemID: UUID?)
    /// 定型文の表示で開く（メニューの「定型文の一覧を開く」。一覧の ⌘S と同じ表示）。実装しなければ `show()`
    func showSnippets()
    func hide()
    /// 履歴が変わった（取り込み・消去）。開いていれば読み直す
    func historyDidChange()
    /// 検証用の状態（絞り込みの語・表示中の行数など。中身は入れない）。実装しなければ空
    var debugState: [String: String] { get }
    /// キーの割り当てが変わった（設定から）。開いていれば画面のヒントもすぐ変える
    func keymapDidChange(_ keymap: Keymap)
    /// 定型文が変わった（定型文の窓・ファイルの書き換え）。開いていれば読み直す
    func snippetsDidChange()
}

extension HistoryPresenting {
    public var debugState: [String: String] { [:] }
    public func show(selecting itemID: UUID?) { show() }
    public func showSnippets() { show() }
    public func keymapDidChange(_ keymap: Keymap) {}
    public func snippetsDidChange() {}
}

/// 貼り付けのしかた
public enum PasteMode: String, Sendable, CaseIterable {
    /// 全型ごと書き戻して ⌘V
    case normal
    /// 文字だけを書き戻して ⌘V（書式を外す。平文の型がなければ全型）
    case plainText
    /// 書き戻すだけで ⌘V は送らない
    case copyOnly
}

@MainActor
public protocol HistoryActions: AnyObject {
    /// 新しい順の履歴（メタデータだけ）
    func historyItems(limit: Int) -> [ClipItem]
    /// 選んだ項目を、元いたアプリへ貼り付ける（UI は先に閉じておく）
    func paste(itemID: UUID)
    /// 貼り方を選んで貼る（UI は先に閉じておく）。既定の実装は `.normal` だけを `paste(itemID:)` に回す
    func paste(itemID: UUID, mode: PasteMode)
    /// UI が閉じた（貼らずに Esc で閉じたときも呼ぶ）
    func historyDidClose()
    /// ピン留めする・外す
    func setPinned(_ pinned: Bool, itemID: UUID)
    /// 履歴から消す
    func delete(itemID: UUID)
    /// 保存した型の一覧（中身なし）。サムネイル・プレビューで読む型を選ぶのに使う
    func representationInfos(itemID: UUID) -> [RepresentationInfo]
    /// 型 1 つのデータ（サムネイル・プレビュー用）。中身は UI の中だけで使い、ログ等に出さない
    func representationData(itemID: UUID, itemIndex: Int, type: String) -> Data?
    /// 設定画面を開く（一覧の ⌘,。UI は先に閉じておく）
    func openSettings()
    /// 定型文（一覧の順）
    func snippets() -> [Snippet]
    /// 定型文の差し込みを置き換えて、元いたアプリへ貼る（UI は先に閉じておく）。履歴には足さない
    func pasteSnippet(id: UUID, mode: PasteMode)
    /// 定型文の窓を開く（UI は先に閉じておく）
    func openSnippetEditor(_ request: SnippetEditRequest)
    /// {{日付}} の書き方（プレビューの説明に使う）
    func snippetDateFormat() -> SnippetDateFormat
}

extension HistoryActions {
    public func paste(itemID: UUID, mode: PasteMode) {
        if mode == .normal { paste(itemID: itemID) }
    }
    public func setPinned(_ pinned: Bool, itemID: UUID) {}
    public func delete(itemID: UUID) {}
    public func representationInfos(itemID: UUID) -> [RepresentationInfo] { [] }
    public func representationData(itemID: UUID, itemIndex: Int, type: String) -> Data? { nil }
    public func openSettings() {}
    public func snippets() -> [Snippet] { [] }
    public func pasteSnippet(id: UUID, mode: PasteMode) {}
    public func openSnippetEditor(_ request: SnippetEditRequest) {}
    public func snippetDateFormat() -> SnippetDateFormat { .default }
}

/// 定型文の窓を開くときの頼み
public enum SnippetEditRequest: Equatable, Sendable {
    /// 開くだけ（前に選んでいたもの、なければ先頭を選ぶ）
    case open
    /// その定型文を選んで開く
    case edit(UUID)
    /// 新しい定型文の下書き（本文を入れておく。保存するまで一覧には足さない）
    case new(body: String)
    /// 履歴の項目の文字から新しい定型文の下書きを作る（本体が文字を読んで `new` にする）
    case fromHistory(UUID)
}

/// 定型文の窓（`MakuripUI` が実装する）。値の読み書きは `SnippetController` を通す
@MainActor
public protocol SnippetEditorPresenting: AnyObject {
    var isVisible: Bool { get }
    /// 窓を出して前面にする
    func show(_ request: SnippetEditRequest)
    func close()
}

/// 定型文の窓が本体に聞くこと
public struct SnippetEditorEnvironment {
    /// {{日付}} の書き方（下書きの見本に使う）
    public var dateFormat: @MainActor () -> SnippetDateFormat

    public init(dateFormat: @escaping @MainActor () -> SnippetDateFormat = { .default }) {
        self.dateFormat = dateFormat
    }
}

/// 設定画面（`MakuripUI` が実装する）。値の読み書きは `SettingsController` を通す
@MainActor
public protocol SettingsPresenting: AnyObject {
    var isVisible: Bool { get }
    /// 窓を出して前面にする（メニューの「設定…」・一覧の ⌘,）
    func show()
    func close()
    /// 本体の状態（ホットキーを登録できたか等）が変わった。開いていれば描き直す
    func environmentDidChange()
}

/// 設定画面が本体に聞くこと・頼むこと
public struct SettingsEnvironment {
    /// バンドル ID のアプリの表示名（入っていなければ nil）
    public var appName: @MainActor (String) -> String?
    /// どこからでも効くキーを登録できたか（分からなければ nil）
    public var hotKeyRegistered: @MainActor (KeyAction) -> Bool?
    /// ログイン時の起動の状態の注記（システム設定で許可が要る等。なければ nil）
    public var launchAtLoginNote: @MainActor () -> String?
    /// キーを記録している間は true（その間、本体はどこからでも効くキーを外す。押したキーを横取りしないように）
    public var recordingDidChange: @MainActor (Bool) -> Void
    /// AI の口（#6）。nil なら設定画面に出さない
    public var aiAccess: AIAccessEnvironment?

    public init(
        appName: @escaping @MainActor (String) -> String? = { _ in nil },
        hotKeyRegistered: @escaping @MainActor (KeyAction) -> Bool? = { _ in nil },
        launchAtLoginNote: @escaping @MainActor () -> String? = { nil },
        recordingDidChange: @escaping @MainActor (Bool) -> Void = { _ in },
        aiAccess: AIAccessEnvironment? = nil
    ) {
        self.appName = appName
        self.hotKeyRegistered = hotKeyRegistered
        self.launchAtLoginNote = launchAtLoginNote
        self.recordingDidChange = recordingDidChange
        self.aiAccess = aiAccess
    }
}

/// 設定画面の「AI の口」が本体に聞くこと・頼むこと。**AI の口をオンにできるのはここ（`setEnabled`）だけ**
public struct AIAccessEnvironment {
    /// いまオンか（DB の `meta` から読む）
    public var isEnabled: @MainActor () -> Bool
    /// 切り替える（設定画面だけが呼ぶ）。書けなければ false
    public var setEnabled: @MainActor (Bool) -> Bool
    /// AI が行った操作の記録（新しい順。メタデータだけ）
    public var recentActivity: @MainActor (Int) -> [AIActivityEntry]
    /// Claude Code に登録するコマンド（画面に出してコピーできるようにする）
    public var registerCommand: @MainActor () -> String
    /// 登録コマンドをクリップボードに置く
    public var copyRegisterCommand: @MainActor () -> Void

    public init(
        isEnabled: @escaping @MainActor () -> Bool, setEnabled: @escaping @MainActor (Bool) -> Bool,
        recentActivity: @escaping @MainActor (Int) -> [AIActivityEntry] = { _ in [] },
        registerCommand: @escaping @MainActor () -> String = { "" },
        copyRegisterCommand: @escaping @MainActor () -> Void = {}
    ) {
        self.isEnabled = isEnabled
        self.setEnabled = setEnabled
        self.recentActivity = recentActivity
        self.registerCommand = registerCommand
        self.copyRegisterCommand = copyRegisterCommand
    }

    /// Claude Code に MCP として登録するコマンド（実行ファイルのパスを入れる）
    public static func claudeRegisterCommand(executablePath: String) -> String {
        let quoted =
            executablePath.contains(where: { $0 == " " || $0 == "'" })
            ? "'\(executablePath.replacingOccurrences(of: "'", with: "'\\''"))'" : executablePath
        return "claude mcp add --scope user makurip -- \(quoted) --mcp"
    }
}
