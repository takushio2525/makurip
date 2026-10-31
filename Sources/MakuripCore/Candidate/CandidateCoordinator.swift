import CoreGraphics
import Foundation

/// 候補窓（⌃⌘V ですぐ貼り、↑↓ で差し替える）の流れをまとめる。
///
/// 画面（`CandidatePresenting`）・キーの横取り（`KeyEventTapping`）・前面のアプリへの操作（`CandidateHost`）は
/// 差し込みにしてあり、単体テストでは偽物で流れ全体（仮貼り → 差し替え → 確定・取り消し）を確かめる。
///
/// **横取りを残さない**のが最優先。閉じる経路（確定・取り消し・広げる・ほかのキー・窓の外のクリック・一定時間の無操作・
/// 前面のアプリの切り替え・窓が閉じられた・画面や操作の環境が変わった・タップが止められた・終了）はすべて `end` を通り、
/// `end` は**その場で**タップを止めて窓を閉じる。文書の後始末（仮に貼ったものを戻す等）はその後で、タップなしで行う。
/// 異常終了したときは、タップはプロセスと一緒に OS が消す（`.agent/conventions.md` の「候補窓」）
///
/// **秘密っぽい項目（`ClipItem.isSecretLikely`）は仮に貼らない**。↑↓ でたどる途中で秘密に来たら、仮に貼ってあるものを戻し、
/// 確定（⇥・↩・ダブルクリック）したときに初めて貼る（相手のアプリの取り消しの履歴・自動保存・共同編集の相手に残さないため。試作どおり）。
/// ほかのキー・窓の外のクリック・無操作で閉じたときは、秘密は貼らない（はっきり確定したときだけ貼る）
@MainActor
public final class CandidateCoordinator {
    public enum EndReason: String, CaseIterable, Sendable {
        case commitKey
        case cancelKey
        case expandKey
        case otherKey
        case clickOutside
        case doubleClick
        case idle
        case appSwitched
        case windowClosed
        case environment
        case tapDisabled
        case shutdown
        case replaceFailed
    }

    public enum StartResult: Equatable, Sendable {
        case started
        /// 許可がない・タップを作れない・前面のアプリがないので、一覧を開いた
        case openedList
        case alreadyActive
        /// 前の候補窓の後始末が終わってから始める
        case queued
    }

    /// ログ用の出来事（メタデータだけ。中身は入れない）
    public enum Event: Sendable {
        case started(method: ReplaceMethod, composing: ComposingState, itemCount: Int)
        case fellBackToList(reason: String)
        case pasted(method: ReplaceMethod, changed: Bool)
        case methodFailed(ReplaceMethod, bundleID: String?)
        case ended(EndReason, method: ReplaceMethod, kept: Bool)
    }

    /// 閉じたあとの文書の扱い
    private enum Finish {
        /// 貼ってあるものを残す。`applyLatest` なら、まだ貼れていない選択を貼ってから終える
        case keep(applyLatest: Bool)
        /// 貼る前に戻す。`openList` なら戻したあとで一覧を開く
        case revert(openList: Bool, selecting: UUID?)
        /// 確定まで貼らない方式で確定した（ここで初めて貼る）
        case pasteSelected
        /// 何もしない（確定まで貼らない方式で、確定以外の理由で閉じた）
        case discard
    }

    /// 文書に仮に貼ってあるもの。範囲を選び直して上から貼るたびに積む（⌘Z は 1 段ずつ戻す）
    private struct Applied {
        var index: Int
        var itemID: UUID
        /// 貼った範囲（測れたとき）
        var range: AXTextRange?
        var content: PastedContent
        /// 貼る直前の入力欄の状態（⌘Z で戻ったかを確かめる基準）
        var before: TextProbe?
    }

    private let host: CandidateHost
    private let presenter: CandidatePresenting
    private let tap: KeyEventTapping
    private let scheduler: CandidateScheduling
    /// 設定から付け替えられる（窓のヒントも同じキーにする）
    public var keymap: Keymap {
        didSet { presenter.keymapDidChange(keymap) }
    }
    public var settings: CandidateSettings
    public var onEvent: ((Event) -> Void)?

    public private(set) var isActive = false
    public private(set) var session = CandidateSession(items: [], order: .terminal)
    public private(set) var method = ReplaceMethod.deferred
    public private(set) var note: CandidateNote?
    public private(set) var lastEndReason: EndReason?
    /// 隠した内容（秘密）を表示しているか（表示のキーを押している間）
    public private(set) var revealed = false
    private var target: CandidateTarget?
    private var composingAtStart = ComposingState.idle
    private var stack: [Applied] = []
    /// 最後に貼ろうとした項目（貼れなかった項目を何度も貼り直さないため）
    private var attempted: Int?
    /// ⌘Z で戻らなかった。これ以上は文書に触らない
    private var documentUntrusted = false
    private var finish: Finish?
    private var worker: Task<Void, Never>?
    private var startWhenIdle = false
    private var idleTimer: CandidateCancellable?
    private var consumedKeyCodes: Set<UInt16> = []
    private var sessionID = 0
    /// アプリごとに失敗した方式（メモリの中だけ。次からはその次の方式で始める）
    private var failures: [String: Set<ReplaceMethod>] = [:]

    public init(
        host: CandidateHost, presenter: CandidatePresenting, tap: KeyEventTapping, scheduler: CandidateScheduling,
        keymap: Keymap = .default, settings: CandidateSettings = .default
    ) {
        self.host = host
        self.presenter = presenter
        self.tap = tap
        self.scheduler = scheduler
        self.keymap = keymap
        self.settings = settings
        presenter.onEvent = { [weak self] event in self?.handlePresenter(event) }
    }

    public var isTapActive: Bool { tap.isActive }
    /// 仮に貼ってあるものがあるか
    public var hasTentativePaste: Bool { !stack.isEmpty }

    public var debugState: [String: String] {
        var state = presenter.debugState
        state["active"] = String(isActive)
        state["tapActive"] = String(tap.isActive)
        state["method"] = method.rawValue
        state["index"] = String(session.index)
        state["count"] = String(session.items.count)
        state["order"] = session.order.rawValue
        state["tentative"] = String(!stack.isEmpty)
        state["note"] = note?.rawValue ?? ""
        state["lastEnd"] = lastEndReason?.rawValue ?? ""
        state["revealed"] = String(revealed)
        state["selectedSecret"] = String(session.selected?.isSecretLikely ?? false)
        return state
    }

    // MARK: 始める

    /// ⌃⌘V（動きが「すぐ貼って候補窓」のとき）
    @discardableResult
    public func start() -> StartResult {
        if isActive { return .alreadyActive }
        if worker != nil {
            startWhenIdle = true
            return .queued
        }
        guard host.canPostKeys else { return fallBackToList("noPermission") }
        guard let target = host.candidateTarget() else { return fallBackToList("noTarget") }

        let items = host.candidateItems()
        session = CandidateSession(items: items, order: settings.order)
        composingAtStart = host.composingState(of: target)
        let timing = settings.timing(for: target.bundleID)
        let probe = timing == .immediate && composingAtStart == .idle ? host.probeText(of: target) : nil
        let override = settings.replaceOverride(for: target.bundleID)
        method = ReplacePlanner.initialMethod(
            timing: timing, composing: composingAtStart, override: override, probe: probe,
            failed: failures[Self.appKey(target)] ?? [])
        note = Self.note(method: method, timing: timing, composing: composingAtStart, probe: probe)
        stack = []
        attempted = nil
        documentUntrusted = false
        finish = nil
        consumedKeyCodes = []
        revealed = false

        guard tap.start({ [weak self] event in self?.handle(event) ?? .pass }) else {
            return fallBackToList("tapUnavailable")
        }
        self.target = target
        sessionID += 1
        isActive = true
        present()
        armIdleTimer()
        onEvent?(.started(method: method, composing: composingAtStart, itemCount: items.count))
        if method != .deferred, !items.isEmpty {
            host.stashPasteboard()
            pump()
        }
        return .started
    }

    /// ⌃⌘V（動きが「すぐ貼るだけ」のとき）。窓は出さない。貼れなければ false
    @discardableResult
    public func pasteLatest() -> Bool {
        guard !isActive, host.canPostKeys, let target = host.candidateTarget(),
            let item = host.candidateItems().first, host.writePasteboard(itemID: item.id) != nil
        else { return false }
        host.send(.paste, to: target)
        host.markUsed(itemID: item.id)
        return true
    }

    private func fallBackToList(_ reason: String) -> StartResult {
        onEvent?(.fellBackToList(reason: reason))
        host.openList(selecting: nil)
        return .openedList
    }

    static func note(method: ReplaceMethod, timing: PasteTiming, composing: ComposingState, probe: TextProbe?)
        -> CandidateNote?
    {
        guard method == .deferred else { return nil }
        if timing == .onCommit { return .deferredApp }
        switch composing {
        case .composing: return .composing
        case .unknown: return .undetermined
        case .idle: return probe == nil ? .unreadable : .replaceUnavailable
        }
    }

    static func appKey(_ target: CandidateTarget) -> String {
        target.bundleID ?? "pid-\(target.pid)"
    }

    // MARK: 操作（キー・クリック・本体から）

    public func perform(_ action: KeyAction) {
        guard isActive else { return }
        switch action {
        case .candidateUp: move(.up)
        case .candidateDown: move(.down)
        case .candidateCommit: commit()
        case .candidateCancel: cancel()
        case .candidateExpand: expand()
        default: break
        }
    }

    public func move(_ direction: CandidateSession.Direction) {
        guard isActive else { return }
        if session.move(direction) {
            selectionChanged()
        } else {
            presenter.bump()
        }
    }

    public func select(index: Int) {
        guard isActive, index != session.index, session.select(index: index) else { return }
        selectionChanged()
    }

    /// Tab・Enter（ダブルクリックも）。秘密は仮に貼っていないので、ここで初めて貼る
    public func commit(_ reason: EndReason = .commitKey) {
        guard isActive else { return }
        let finish: Finish
        if let selected = session.selected, method == .deferred || selected.isSecretLikely {
            finish = .pasteSelected
        } else {
            finish = method == .deferred ? .discard : .keep(applyLatest: true)
        }
        end(reason, finish: finish)
    }

    /// Esc: 貼る前に戻す
    public func cancel() {
        end(.cancelKey, finish: .revert(openList: false, selecting: nil))
    }

    /// 一覧へ広げる: 仮に貼ったものを戻し、選んでいた項目を選んだ状態で一覧を開く
    public func expand() {
        end(.expandKey, finish: .revert(openList: true, selecting: session.selected?.id))
    }

    /// 前面のアプリが変わった（NSWorkspace の通知から）
    public func frontmostAppDidChange(pid: pid_t?) {
        guard isActive, pid != target?.pid else { return }
        end(.appSwitched, finish: implicitFinish(applyLatest: false))
    }

    /// スペースの切り替え・画面のスリープ・ログアウト画面・画面の構成の変化
    public func environmentDidChange() {
        end(.environment, finish: implicitFinish(applyLatest: false))
    }

    /// Makurip の終了
    public func shutdown() {
        end(.shutdown, finish: implicitFinish(applyLatest: false))
    }

    /// 確定のキー以外で閉じたとき。秘密を選んでいたら、はっきり確定していないので貼らず、仮に貼ったものも戻す
    private func implicitFinish(applyLatest: Bool) -> Finish {
        if method == .deferred { return .discard }
        if applyLatest, session.selected?.isSecretLikely == true { return .revert(openList: false, selecting: nil) }
        return .keep(applyLatest: applyLatest)
    }

    private func selectionChanged() {
        armIdleTimer()
        present()
        pump()
    }

    // MARK: 横取りしたキー・クリック

    /// タップから呼ばれる。すぐ返す（重い処理はしない）
    func handle(_ event: KeyTapEvent) -> KeyTapDecision {
        guard isActive else { return .pass }
        switch event {
        case .disabled:
            // 付け直さない（応答が遅れた状態で横取りを続けると、キーが行方不明になりうる）
            end(.tapDisabled, finish: implicitFinish(applyLatest: false))
            return .pass
        case .mouseDown(let point):
            if presenter.contains(screenPoint: point) {
                armIdleTimer()
                return .pass
            }
            end(.clickOutside, finish: implicitFinish(applyLatest: true))
            return .pass
        case .keyUp(let keyCode):
            return consumedKeyCodes.remove(keyCode) != nil ? .consume : .pass
        case .flagsChanged(let modifiers):
            // 修飾キーは食べない（⌥ などを前面のアプリにも届ける）。表示のキーを押している間だけ秘密を表示する
            let held = keymap.isHeld(.reveal, modifiers: modifiers)
            if held != revealed {
                revealed = held
                present()
            }
            return .pass
        case .keyDown(let press):
            // 変換中に始めたときは、変換が終わるまで何も横取りしない（確定の Enter や候補選びの ↑↓ は日本語入力のもの）
            if composingAtStart == .composing, let target, host.composingState(of: target) == .composing {
                return .pass
            }
            // どこからでも効くキー（⌃⌘V など）は Carbon のホットキーに任せる（候補窓が出ていれば広げる）
            if keymap.action(for: press, scope: .global) != nil { return .pass }
            // 表示のキー（⌥）を押したままでも確定・取り消し・↑↓ を効かせる（⌥ で秘密を見ながら ⇥ で確定する。#28）
            guard let (action, _) = keymap.action(for: press, scope: .candidate, ignoringHeld: .reveal) else {
                // それ以外のキーは確定して、そのキーは前面のアプリへそのまま渡す（予測変換と同じ）
                end(.otherKey, finish: implicitFinish(applyLatest: true))
                return .pass
            }
            consumedKeyCodes.insert(press.keyCode)
            armIdleTimer()
            perform(action)
            return .consume
        }
    }

    private func handlePresenter(_ event: CandidatePresenterEvent) {
        guard isActive else { return }
        switch event {
        case .clicked(let index):
            armIdleTimer()
            select(index: index)
        case .doubleClicked(let index):
            select(index: index)
            commit(.doubleClick)
        case .closed:
            end(.windowClosed, finish: implicitFinish(applyLatest: false))
        }
    }

    private func armIdleTimer() {
        idleTimer?.cancel()
        idleTimer = scheduler.after(settings.idleTimeout) { [weak self] in
            guard let self, self.isActive else { return }
            self.end(.idle, finish: self.implicitFinish(applyLatest: true))
        }
    }

    private func present() {
        presenter.present(
            CandidateViewState(
                sessionID: sessionID, items: session.items, selectedIndex: session.index, order: session.order,
                note: note, target: target, revealed: revealed))
    }

    // MARK: 閉じる（すべての経路がここを通る）

    private func end(_ reason: EndReason, finish: Finish) {
        guard isActive else { return }
        isActive = false
        revealed = false
        // 横取りを先に外す。後始末（文書を戻す等）はタップなしで行う
        tap.stop()
        idleTimer?.cancel()
        idleTimer = nil
        consumedKeyCodes.removeAll()
        presenter.dismiss()
        lastEndReason = reason
        self.finish = finish
        pump()
    }

    // MARK: 文書への反映（1 つずつ順に。キーを送ったら相手が処理し終えるのを待つ）

    private func pump() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    /// 後始末と差し替えが終わるまで待つ（テスト用）
    func waitUntilIdle() async {
        while let worker {
            await worker.value
        }
    }

    private func drain() async {
        while true {
            if let finish {
                self.finish = nil
                await complete(finish)
                resetSession()
                continue
            }
            guard isActive, method != .deferred, !documentUntrusted, attempted != session.index else { break }
            await apply(session.index)
        }
        worker = nil
        if startWhenIdle {
            startWhenIdle = false
            start()
        }
    }

    private func complete(_ finish: Finish) async {
        var kept = false
        switch finish {
        case .keep(let applyLatest):
            if applyLatest, method != .deferred, !documentUntrusted, attempted != session.index {
                await apply(session.index)
            }
            if let top = stack.last {
                host.markUsed(itemID: top.itemID)
                host.discardPasteboardStash()
                kept = true
            } else {
                host.restorePasteboard()
            }
        case .revert(let openList, let selecting):
            if !stack.isEmpty, !documentUntrusted { await removeAll() }
            host.restorePasteboard()
            // 戻し終えてから開く（一覧が窓の焦点を取ると、送ったキーが相手の入力欄に届かなくなるため）
            if openList { host.openList(selecting: selecting) }
        case .pasteSelected:
            // 秘密を確定したとき、前に仮に貼ったもの（秘密に移ってすぐ確定して、まだ戻していない分）を先に戻す
            if !stack.isEmpty, !documentUntrusted { await removeAll() }
            if let target, stack.isEmpty, let item = session.selected, host.writePasteboard(itemID: item.id) != nil {
                host.send(.paste, to: target)
                host.markUsed(itemID: item.id)
                host.discardPasteboardStash()
                kept = true
            } else {
                host.restorePasteboard()
            }
        case .discard:
            break
        }
        onEvent?(.ended(lastEndReason ?? .shutdown, method: method, kept: kept))
    }

    private func resetSession() {
        stack = []
        attempted = nil
        target = nil
        documentUntrusted = false
    }

    /// 選んでいる項目を文書に仮に貼る（貼ってあるものがあれば差し替える）。秘密は貼らず、仮に貼ってあるものを戻すだけ
    private func apply(_ index: Int) async {
        guard let target, session.items.indices.contains(index) else { return }
        attempted = index
        if session.items[index].isSecretLikely {
            if !stack.isEmpty { await removeAll() }
            return
        }
        while let top = stack.last, top.index != index {
            if method == .selectRange,
                ReplacePlanner.canReselect(measured: top.range, expectedLength: top.content.textLength),
                let range = top.range
            {
                if await reselect(range, in: target) {
                    await paste(index, replacing: range, in: target)
                    return
                }
                // 範囲を選び直せないアプリ。このセッションは ⌘Z に切り替え、次からは ⌘Z で始める
                recordFailure(.selectRange, target: target)
                method = .undo
            }
            guard await undoOnce(in: target) else { return }
        }
        if stack.isEmpty { await paste(index, replacing: nil, in: target) }
    }

    private func paste(_ index: Int, replacing: AXTextRange?, in target: CandidateTarget) async {
        let item = session.items[index]
        let before = host.probeText(of: target)
        guard let content = host.writePasteboard(itemID: item.id) else { return }
        host.send(.paste, to: target)
        guard let before else {
            // 入力欄を読めない（決め打ちで ⌘Z にしたアプリ）。少し待って貼れたものとみなす
            await host.pause(milliseconds: 150)
            stack.append(Applied(index: index, itemID: item.id, range: nil, content: content, before: nil))
            onEvent?(.pasted(method: method, changed: true))
            return
        }
        guard let after = await waitForProbe(in: target, { $0 != before }) else {
            // 何も変わらない（受け付けない中身・入力欄でない）。差し替えのときは前の中身が選ばれたまま残る
            onEvent?(.pasted(method: method, changed: false))
            return
        }
        let range = ReplacePlanner.pastedRange(before: before, after: after, replacing: replacing)
        stack.append(Applied(index: index, itemID: item.id, range: range, content: content, before: before))
        onEvent?(.pasted(method: method, changed: true))
    }

    private func reselect(_ range: AXTextRange, in target: CandidateTarget) async -> Bool {
        guard host.selectText(range, in: target) else { return false }
        return await waitForProbe(in: target, timeoutMilliseconds: 200, { $0.selection == range }) != nil
    }

    /// ⌘Z で 1 段戻す。戻ったことを確かめられなければ ⌘⇧Z で打ち消し、貼ってあるもので終える（文書を壊さないため）
    private func undoOnce(in target: CandidateTarget) async -> Bool {
        guard let top = stack.last else { return true }
        host.send(.undo, to: target)
        guard let expected = top.before else {
            await host.pause(milliseconds: 150)
            stack.removeLast()
            return true
        }
        if await waitForProbe(in: target, { ReplacePlanner.isRestored($0, baseline: expected) }) != nil {
            stack.removeLast()
            return true
        }
        host.send(.redo, to: target)
        await host.pause(milliseconds: 100)
        recordFailure(.undo, target: target)
        documentUntrusted = true
        end(.replaceFailed, finish: .keep(applyLatest: false))
        return false
    }

    /// 仮に貼ったものをすべて戻す（取り消し・広げる）
    private func removeAll() async {
        guard let target else { return }
        while let top = stack.last {
            if method == .selectRange,
                ReplacePlanner.canReselect(measured: top.range, expectedLength: top.content.textLength),
                let range = top.range
            {
                if await reselect(range, in: target) {
                    // 範囲を選び直して貼るたびに前の中身は置き換わっているので、いちばん上を消せば貼る前に戻る
                    host.send(.deleteBackward, to: target)
                    if let base = stack.first?.before {
                        _ = await waitForProbe(in: target, { ReplacePlanner.isRestored($0, baseline: base) })
                    } else {
                        await host.pause(milliseconds: 100)
                    }
                    stack.removeAll()
                    return
                }
                recordFailure(.selectRange, target: target)
                method = .undo
            }
            guard await undoOnce(in: target) else { return }
        }
    }

    private func waitForProbe(
        in target: CandidateTarget, timeoutMilliseconds: Int = 600, _ condition: (TextProbe) -> Bool
    ) async -> TextProbe? {
        var waited = 0
        while true {
            if let probe = host.probeText(of: target), condition(probe) { return probe }
            if waited >= timeoutMilliseconds { return nil }
            await host.pause(milliseconds: 20)
            waited += 20
        }
    }

    private func recordFailure(_ failed: ReplaceMethod, target: CandidateTarget) {
        failures[Self.appKey(target), default: []].insert(failed)
        onEvent?(.methodFailed(failed, bundleID: target.bundleID))
    }
}
