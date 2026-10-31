import Foundation

/// 文字の範囲（AX の `CFRange` と同じ。単位は UTF-16）
public struct AXTextRange: Hashable, Sendable, CustomStringConvertible {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public var description: String { "{\(location), \(length)}" }
}

/// 前面のアプリの入力欄の状態（AX で読めたもの）。中身の文字は持たない
public struct TextProbe: Hashable, Sendable {
    /// 選択範囲（長さ 0 なら文字カーソルの位置）
    public var selection: AXTextRange
    /// 入力欄の全体の文字数（読めなければ nil）
    public var characterCount: Int?
    /// 選択範囲を AX で書き換えられるか
    public var selectionSettable: Bool

    public init(selection: AXTextRange, characterCount: Int?, selectionSettable: Bool) {
        self.selection = selection
        self.characterCount = characterCount
        self.selectionSettable = selectionSettable
    }
}

/// 日本語入力の変換中か（他のアプリの入力欄について）
public enum ComposingState: String, Sendable {
    /// 未確定の文字がある
    case composing
    /// 未確定の文字はない
    case idle
    /// 判定できない（AX で読めず、入力ソースが日本語入力などの入力方式）
    case unknown

    /// 判定の決まり。`markedTextLength` は AX の `AXTextInputMarkedRange` の長さ（読めなければ nil）、
    /// `inputMethodActive` は入力ソースが英字以外の入力方式か（日本語入力のかな入力など）。
    ///
    /// AX が「未確定の文字がない」と答えたらそれを信じる。AX が読めないときは、入力方式が英字なら変換中ではありえないので
    /// `.idle`、日本語入力のかなモードなどなら `.unknown`（安全側に倒す。扱いは `ReplacePlanner.initialMethod`）
    public static func decide(markedTextLength: Int?, inputMethodActive: Bool) -> ComposingState {
        if let markedTextLength { return markedTextLength > 0 ? .composing : .idle }
        return inputMethodActive ? .unknown : .idle
    }
}

/// 仮に貼った中身を差し替える・取り消すしかた
public enum ReplaceMethod: String, CaseIterable, Sendable, Codable {
    /// 直前に貼った範囲を AX で選び直し、その上に貼る（取り消しは選んで ⌫）
    case selectRange
    /// ⌘Z で貼る前に戻してから貼る（取り消しは ⌘Z）
    case undo
    /// 仮に貼らない。確定したときに初めて貼る
    case deferred
}

/// 差し替え方式の決め方（純粋関数）。アプリによって効く方式が違うので、効くかどうかを AX で確かめながら
/// 「範囲を選び直す → ⌘Z → 確定まで貼らない」の順に落とす。失敗した方式はアプリごとに覚え（メモリの中だけ）、
/// 次からはその次の方式で始める
public enum ReplacePlanner {
    /// 候補窓を始めるときの方式
    ///
    /// - 確定まで貼らないアプリ（`PasteTiming.onCommit`）→ `.deferred`
    /// - 変換中・変換中か分からない → `.deferred`（未確定の文字があるところへ ⌘V を送ると、確定のされ方がアプリで違うため）
    /// - アプリごとの決め打ちがあればそれ（`.selectRange` は選択範囲を読めるときだけ）
    /// - 選択範囲を AX で読めない → `.deferred`。⌘Z が貼り付けを戻したかを確かめられないまま送ると、
    ///   入力欄でない所（Finder の一覧など）では別の操作を取り消してしまうため
    /// - 選択範囲を書ける・始めに選択がない → `.selectRange`（選択があると、貼り付けが選択を置き換えるので
    ///   範囲を消しても元の文字は戻らない。⌘Z なら戻る）
    /// - それ以外 → `.undo`。どちらも失敗したことがあるアプリ → `.deferred`
    public static func initialMethod(
        timing: PasteTiming, composing: ComposingState, override: ReplaceMethod?, probe: TextProbe?,
        failed: Set<ReplaceMethod>
    ) -> ReplaceMethod {
        if timing == .onCommit || composing != .idle { return .deferred }
        if let override { return override == .selectRange && probe == nil ? .deferred : override }
        guard let probe else { return .deferred }
        if probe.selectionSettable, probe.selection.length == 0, !failed.contains(.selectRange) {
            return .selectRange
        }
        return failed.contains(.undo) ? .deferred : .undo
    }

    /// 貼った範囲を AX で選び直して消せるか。文字だけの中身で、貼る前後の文字カーソルから測った長さが
    /// 中身の文字数と同じときだけ（画像・リッチテキストの添付は 1 文字になるなど、長さが合わないため）
    public static func canReselect(measured: AXTextRange?, expectedLength: Int?) -> Bool {
        guard let measured, let expectedLength, measured.length > 0 else { return false }
        return measured.length == expectedLength
    }

    /// 貼る前と後の状態から、貼った範囲を測る。文字カーソルが前へ進んでいなければ nil（貼れていない）
    public static func pastedRange(before: TextProbe, after: TextProbe, replacing: AXTextRange?) -> AXTextRange? {
        let start = replacing?.location ?? before.selection.location
        guard after.selection.length == 0, after.selection.location > start else { return nil }
        return AXTextRange(location: start, length: after.selection.location - start)
    }

    /// ⌘Z で貼る前に戻ったか。選択の位置と文字数（読めれば）が始める前と同じなら戻ったとみなす
    public static func isRestored(_ probe: TextProbe, baseline: TextProbe) -> Bool {
        guard probe.selection.location == baseline.selection.location else { return false }
        if let count = probe.characterCount, let expected = baseline.characterCount { return count == expected }
        return probe.selection == baseline.selection
    }
}

/// ⌃⌘V・⌃⌥⌘V を押したときに何をするか（純粋関数）
public enum HotKeyRouter {
    public enum Key: Sendable {
        /// 履歴を呼び出す（⌃⌘V）
        case open
        /// 一覧を開く（⌃⌥⌘V）
        case openList
    }

    public enum Route: Equatable, Sendable {
        case pasteLatest
        case startCandidate
        case openList
        case closeList
        case expandCandidate
    }

    /// 候補窓が出ているときはどちらのキーでも一覧へ広げる（試作と同じ）。一覧が開いているときはどちらのキーでも閉じる
    public static func route(_ key: Key, mode: HotKeyMode, candidateActive: Bool, listVisible: Bool) -> Route {
        if candidateActive { return .expandCandidate }
        if listVisible { return .closeList }
        if key == .openList { return .openList }
        switch mode {
        case .pasteOnly: return .pasteLatest
        case .candidate: return .startCandidate
        case .list: return .openList
        }
    }
}
