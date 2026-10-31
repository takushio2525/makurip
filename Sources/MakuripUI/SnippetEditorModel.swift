import Foundation
import MakuripCore
import Observation

/// 定型文の窓の状態と操作。値の検証と保存は `SnippetController`（Core）を通す。
///
/// 編集は下書き（`draft`）に入れ、保存（⌘S・ボタン）で確定する。ほかの定型文を選ぶ・新しく作る・窓を閉じるときは、
/// 変更があって検証に通れば自動で保存する（通らなければ、選び直しは止めて理由を出す。閉じるときは前の値のまま）。
/// 新しい下書きは、開いたときのまま（履歴から作った本文に手を付けていない等）なら保存しない
@MainActor
@Observable
final class SnippetEditorModel {
    struct Effects {
        var close: () -> Void = {}
        /// 削除の確かめ（名前・答え）。テストではすぐ答える
        var confirmDelete: @MainActor (String, @escaping @MainActor (Bool) -> Void) -> Void = { _, answer in
            answer(true)
        }
    }

    enum Selection: Hashable {
        case snippet(UUID)
        /// まだ保存していない新しい定型文
        case draft
    }

    enum Field: Hashable {
        case name
        case abbreviation
        case body
    }

    struct Message: Equatable {
        var text: String
        var isError = false
    }

    @ObservationIgnored let controller: SnippetController
    @ObservationIgnored let environment: SnippetEditorEnvironment
    @ObservationIgnored var effects = Effects()
    @ObservationIgnored private var observer: UUID?

    private(set) var snippets: [Snippet]
    private(set) var selection: Selection?
    /// 入力欄に出している値
    var draft = SnippetDraft()
    /// 本文の選択範囲（UTF-16）。差し込みの札はここに入れる。本文の入力欄が書き換える
    var bodySelection = NSRange(location: 0, length: 0)
    /// 本文の選択範囲を入力欄へ当て直す合図（差し込みを入れたとき）
    private(set) var bodySelectionRevision = 0
    private(set) var message: Message?
    /// 入力欄へフォーカスを移す合図
    private(set) var focusRequest: (field: Field, revision: Int)?
    /// 本文の入力欄にフォーカスがあるか（入力欄が知らせる。枠の色に使う）
    var bodyFocused = false
    /// 保存してある値（変更の有無を見る）。新しい下書きは開いたときの値
    private var baseline = SnippetDraft()

    init(controller: SnippetController, environment: SnippetEditorEnvironment = SnippetEditorEnvironment()) {
        self.controller = controller
        self.environment = environment
        snippets = controller.snippets
        observer = controller.observe { [weak self] collection in
            self?.collectionDidChange(collection)
        }
    }

    /// 知らせを外す（窓を捨てるとき。外さなくても弱い参照なので何もしない）
    func detach() {
        if let observer { controller.removeObserver(observer) }
        observer = nil
    }

    var isDirty: Bool { draft != baseline }
    var issues: [String] { controller.issues }
    var isDraft: Bool { selection == .draft }

    var selectedSnippet: Snippet? {
        guard case .snippet(let id) = selection else { return nil }
        return snippets.first { $0.id == id }
    }

    var selectedIndex: Int? {
        guard case .snippet(let id) = selection else { return nil }
        return snippets.firstIndex { $0.id == id }
    }

    /// 一覧に出す名前（下書きは「新しい定型文」か、書いた名前・本文の 1 行目）
    var draftTitle: String {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let derived = SnippetCollection.derivedName(from: draft.body)
        return derived.isEmpty ? "新しい定型文" : derived
    }

    // MARK: 開く

    func open(_ request: SnippetEditRequest) {
        snippets = controller.snippets
        switch request {
        case .open, .fromHistory:
            if selection == .draft || selectedSnippet != nil { return }
            if let first = snippets.first {
                select(first.id)
            } else {
                beginNew()
            }
        case .edit(let id):
            if snippets.contains(where: { $0.id == id }) {
                select(id)
            } else {
                open(.open)
                message = Message(text: "その定型文は見つかりませんでした（消されたかもしれません）。", isError: true)
            }
        case .new(let body):
            beginNew(body: body)
        }
    }

    // MARK: 選ぶ・作る

    /// ほかを選ぶ。今の下書きに変更があれば保存してから（通らなければ選び直さない）
    func select(_ id: UUID) {
        guard selection != .snippet(id) else { return }
        guard leaveCurrent(), let snippet = snippets.first(where: { $0.id == id }) else { return }
        selection = .snippet(id)
        load(snippet.draft)
        message = nil
    }

    /// 一覧で上下に動かす（入力欄の外にいるとき）
    func selectNeighbor(_ delta: Int) {
        guard !snippets.isEmpty else { return }
        let current = selectedIndex ?? (delta > 0 ? -1 : snippets.count)
        let next = min(max(0, current + delta), snippets.count - 1)
        select(snippets[next].id)
    }

    /// 新しい下書き（本文を入れておける）。保存するまで一覧には足さない
    func beginNew(body: String = "") {
        guard leaveCurrent() else { return }
        selection = .draft
        load(SnippetDraft(body: body))
        message = nil
        requestFocus(body.isEmpty ? .body : .name)
    }

    private func load(_ value: SnippetDraft) {
        draft = value
        baseline = value
        bodySelection = NSRange(location: (value.body as NSString).length, length: 0)
        bodySelectionRevision += 1
    }

    private func requestFocus(_ field: Field) {
        focusRequest = (field, (focusRequest?.revision ?? 0) + 1)
    }

    /// 今の下書きを離れてよいか（変更があれば保存を試す）
    private func leaveCurrent() -> Bool {
        guard selection != nil, isDirty else { return true }
        return save()
    }

    // MARK: 保存・取り消し・削除・並べ替え

    /// 下書きを確定する。通らなければ理由を出して false
    @discardableResult
    func save() -> Bool {
        do {
            let saved: Snippet
            switch selection {
            case .snippet(let id):
                saved = try controller.update(id: id, with: draft)
            case .draft, nil:
                saved = try controller.add(draft)
            }
            snippets = controller.snippets
            selection = .snippet(saved.id)
            draft = saved.draft
            baseline = saved.draft
            message = Message(text: "「\(saved.name)」を保存しました。")
            return true
        } catch let error as SnippetError {
            message = Message(text: error.message + "。", isError: true)
            switch error.field {
            case .name: requestFocus(.name)
            case .abbreviation: requestFocus(.abbreviation)
            case .body: requestFocus(.body)
            case .list: break
            }
            return false
        } catch {
            message = Message(text: "保存できませんでした（\(error.localizedDescription)）。", isError: true)
            return false
        }
    }

    /// esc: 変更があれば保存してある値に戻す。新しい下書きなら捨てる。変更がなければ窓を閉じる
    func cancel() {
        guard isDirty || isDraft else {
            effects.close()
            return
        }
        if isDraft {
            discardDraft()
        } else {
            draft = baseline
            bodySelectionRevision += 1
            message = Message(text: "変更を取り消しました。")
        }
    }

    private func discardDraft() {
        selection = nil
        baseline = SnippetDraft()
        draft = SnippetDraft()
        if let first = snippets.first {
            select(first.id)
        }
        message = Message(text: "新しい定型文を取り消しました。")
    }

    /// 選んでいる定型文を消す（確かめてから）。下書きなら捨てる
    func deleteSelected() {
        if isDraft {
            discardDraft()
            return
        }
        guard let snippet = selectedSnippet, let index = selectedIndex else { return }
        effects.confirmDelete(snippet.name) { [weak self] confirmed in
            guard let self, confirmed else { return }
            do {
                try self.controller.remove(id: snippet.id)
                self.snippets = self.controller.snippets
                self.selection = nil
                self.baseline = SnippetDraft()
                self.draft = SnippetDraft()
                if !self.snippets.isEmpty {
                    self.select(self.snippets[min(index, self.snippets.count - 1)].id)
                }
                self.message = Message(text: "「\(snippet.name)」を削除しました。")
            } catch {
                self.message = Message(text: "削除できませんでした。", isError: true)
            }
        }
    }

    /// 選んでいる定型文を 1 つ上・下へ（一覧と ⌘1〜9 の順）
    func moveSelected(by delta: Int) {
        guard let snippet = selectedSnippet else { return }
        do {
            if try controller.move(id: snippet.id, by: delta) {
                snippets = controller.snippets
            }
        } catch {
            message = Message(text: "並べ替えられませんでした。", isError: true)
        }
    }

    /// 差し込みの札を、本文の選択範囲に入れる（選んでいた文字は置き換える）
    func insert(_ placeholder: SnippetPlaceholder) {
        let body = draft.body as NSString
        let location = min(max(0, bodySelection.location), body.length)
        let length = min(max(0, bodySelection.length), body.length - location)
        draft.body = body.replacingCharacters(in: NSRange(location: location, length: length), with: placeholder.token)
        bodySelection = NSRange(location: location + (placeholder.token as NSString).length, length: 0)
        bodySelectionRevision += 1
        requestFocus(.body)
    }

    /// 窓を閉じる直前。変更があって検証に通れば保存する（通らなければ前の値のまま）
    func windowWillClose() {
        if isDirty, selection != nil { _ = save() }
        message = nil
    }

    // MARK: ファイルの変化（AI の口・手での書き換え）

    private func collectionDidChange(_ collection: SnippetCollection) {
        snippets = collection.snippets
        guard case .snippet(let id) = selection else { return }
        if let snippet = collection.snippet(id: id) {
            // 手を付けていなければ、外での書き換えを入力欄にも出す
            if !isDirty, snippet.draft != draft { load(snippet.draft) }
        } else if isDirty {
            // 編集中に外で消されたら、書いていたものは新しい下書きとして残す
            selection = .draft
            baseline = SnippetDraft()
            message = Message(text: "編集中の定型文がほかで消されたので、新しい定型文として残しました。", isError: true)
        } else {
            selection = nil
            if let first = snippets.first { select(first.id) }
        }
    }

    // MARK: 説明

    /// 差し込みが何に置き換わるか（日付は今日の日付を設定の書き方で）
    func placeholderSummary(_ placeholder: SnippetPlaceholder, now: Date = Date()) -> String {
        placeholder == .date
            ? "\(placeholder.summary)（\(environment.dateFormat().format(now))）" : placeholder.summary
    }
}
