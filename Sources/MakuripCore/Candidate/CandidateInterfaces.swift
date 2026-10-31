import CoreGraphics
import Foundation

/// 貼る先（候補窓を出したときに前面にいたアプリ）
public struct CandidateTarget: Hashable, Sendable {
    public var pid: pid_t
    public var bundleID: String?

    public init(pid: pid_t, bundleID: String?) {
        self.pid = pid
        self.bundleID = bundleID
    }
}

/// 前面のアプリへ pid 宛てに送るキー（`CGEvent.postToPid`。前面のアプリを activate しない）
public enum SyntheticKey: String, Sendable {
    /// ⌘V
    case paste
    /// ⌘Z
    case undo
    /// ⌘⇧Z（⌘Z で戻らなかったときに打ち消す）
    case redo
    /// ⌫（選んだ範囲を消す）
    case deleteBackward
}

/// Makurip が送ったキーに付ける印（`CGEventField.eventSourceUserData`）。横取りのタップはこの印の付いたキーを素通しする
public enum SyntheticEventMarker {
    public static let userData: Int64 = 0x4D4B_5250  // 'MKRP'
}

/// ペーストボードへ書いた中身の要点（差し替えの方式を決めるのに使う。中身の文字は持たない）
public struct PastedContent: Hashable, Sendable {
    /// 文字だけの中身なら、その UTF-16 の長さ（入力欄に貼るとこの文字数だけ増えるはず）。画像・ファイル・リッチテキストは nil
    public var textLength: Int?

    public init(textLength: Int?) {
        self.textLength = textLength
    }
}

/// 候補窓が本体（アプリ）に頼むこと。AX・ペーストボード・キーの送信・ストアはここを通す（テストでは偽物に差し替える）
@MainActor
public protocol CandidateHost: AnyObject {
    /// 新しい順の履歴（メタデータだけ）
    func candidateItems() -> [ClipItem]
    /// 前面のアプリ（Makurip 自身・前面のアプリがないときは nil）
    func candidateTarget() -> CandidateTarget?
    /// キーを送れるか（アクセシビリティの許可）
    var canPostKeys: Bool { get }
    func composingState(of target: CandidateTarget) -> ComposingState
    /// 入力欄の選択範囲と文字数（AX）。読めなければ nil
    func probeText(of target: CandidateTarget) -> TextProbe?
    /// 入力欄の選択範囲を AX で書き換える。書けなければ false
    func selectText(_ range: AXTextRange, in target: CandidateTarget) -> Bool
    /// いまのペーストボードを丸ごとメモリに控える（取り消しで戻すため。保存はしない）
    func stashPasteboard()
    /// 控えたものをペーストボードへ戻して控えを捨てる（新しい履歴にしない）。控えがなければ何もしない
    func restorePasteboard()
    func discardPasteboardStash()
    /// 履歴の 1 件をペーストボードへ書く（新しい履歴にしない）。読めなければ nil
    func writePasteboard(itemID: UUID) -> PastedContent?
    func send(_ key: SyntheticKey, to target: CandidateTarget)
    /// 確定した項目を履歴の先頭へ移す
    func markUsed(itemID: UUID)
    /// 一覧（パネル B）を開く。`itemID` があればそれを選んだ状態で
    func openList(selecting itemID: UUID?)
    /// 送ったキーを相手のアプリが処理するのを待つ（テストではすぐ返す）
    func pause(milliseconds: Int) async
}

/// 横取りのタップから届くもの
public enum KeyTapEvent: Sendable, Equatable {
    case keyDown(KeyStroke)
    case keyUp(keyCode: UInt16)
    /// 画面の点（CoreGraphics の座標。主画面の左上が原点）
    case mouseDown(CGPoint)
    /// 修飾キーの押し離し（いま押されている修飾キー）。食べずに素通しする（隠した内容の表示に使う）
    case flagsChanged(HotKey.Modifiers)
    /// システムがタップを止めた（応答が遅い・ユーザーの操作で無効）。付け直さずに候補窓を閉じる
    case disabled
}

public enum KeyTapDecision: Sendable, Equatable {
    /// 前面のアプリへそのまま渡す
    case pass
    /// 食べる（前面のアプリに届けない）
    case consume
}

/// キーの横取り（本番は CGEventTap）。**候補窓が出ている間だけ**動かす。止めたら二度と handler を呼ばない
@MainActor
public protocol KeyEventTapping: AnyObject {
    var isActive: Bool { get }
    /// 始める。作れなければ（許可がない等）false
    func start(_ handler: @escaping @MainActor (KeyTapEvent) -> KeyTapDecision) -> Bool
    func stop()
}

@MainActor
public protocol CandidateCancellable: AnyObject {
    func cancel()
}

/// 一定時間後の処理（何も押さないまま時間がたったら閉じる）。テストでは手で進める
@MainActor
public protocol CandidateScheduling: AnyObject {
    func after(_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> CandidateCancellable
}

/// 候補窓の下に出す注記（仮に貼らない理由）
public enum CandidateNote: String, Sendable {
    /// ターミナル・チャットなど、確定まで貼らないアプリ
    case deferredApp
    /// 日本語入力の変換中
    case composing
    /// 変換中か判定できない
    case undetermined
    /// 入力欄の選択範囲を AX で読めない（仮に貼っても、戻ったかを確かめられない）
    case unreadable
    /// このアプリでは差し替えがうまくいかなかった
    case replaceUnavailable

    /// 窓の幅に 1 行で収まる長さ（27 文字まで）にしてある
    public var text: String {
        switch self {
        case .deferredApp: "このアプリでは、確定したときに貼ります。"
        case .composing: "変換中なので、確定したときに貼ります。"
        case .undetermined: "入力の状態が分からないので、確定したときに貼ります。"
        case .unreadable: "入力欄を読めないので、確定したときに貼ります。"
        case .replaceUnavailable: "差し替えられないアプリなので、確定したときに貼ります。"
        }
    }
}

/// 候補窓の画面に渡すもの
public struct CandidateViewState: Equatable, Sendable {
    /// 始めるたびに増える（窓の位置を決め直す合図）
    public var sessionID: Int
    /// 新しい順
    public var items: [ClipItem]
    public var selectedIndex: Int
    public var order: CandidateOrder
    public var note: CandidateNote?
    public var target: CandidateTarget?
    /// 隠した内容（秘密）を表示しているか（表示のキーを押している間だけ true）
    public var revealed: Bool

    public init(
        sessionID: Int, items: [ClipItem], selectedIndex: Int, order: CandidateOrder, note: CandidateNote?,
        target: CandidateTarget?, revealed: Bool = false
    ) {
        self.sessionID = sessionID
        self.items = items
        self.selectedIndex = selectedIndex
        self.order = order
        self.note = note
        self.target = target
        self.revealed = revealed
    }

    public var selectedItem: ClipItem? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }
}

public enum CandidatePresenterEvent: Sendable, Equatable {
    /// 行をクリックした（`items` の添字）
    case clicked(Int)
    case doubleClicked(Int)
    /// 窓が外から閉じられた
    case closed
}

/// 候補窓の画面（`MakuripUI` が実装する）。窓はキーの焦点を取らない（前面のアプリに入力を残す）
@MainActor
public protocol CandidatePresenting: AnyObject {
    var isVisible: Bool { get }
    var onEvent: ((CandidatePresenterEvent) -> Void)? { get set }
    /// 出す・中身を変える。`sessionID` が変わったときだけ文字カーソルの位置を取り直す
    func present(_ state: CandidateViewState)
    func dismiss()
    /// 端で動けなかったときに揺らす
    func bump()
    /// 画面の点（CoreGraphics の座標）が窓の中か
    func contains(screenPoint: CGPoint) -> Bool
    /// 検証用の状態（中身は入れない）
    var debugState: [String: String] { get }
    /// キーの割り当てが変わった（窓の下のヒントに使う）
    func keymapDidChange(_ keymap: Keymap)
}

extension CandidatePresenting {
    public var debugState: [String: String] { [:] }
    public func keymapDidChange(_ keymap: Keymap) {}
}
