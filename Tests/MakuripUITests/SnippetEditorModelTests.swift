import AppKit
import Foundation
import MakuripCore
import Testing

@testable import MakuripUI

/// 定型文の窓の操作（モデルを直接駆動し、保存は一時フォルダの本物のファイルに書く。窓は作らない）
@MainActor
@Suite("定型文の窓")
struct SnippetEditorModelTests {
    final class Box {
        var closed = 0
        var asked: [String] = []
        var answer = true
    }

    let dir = SettingsTempDirectory()
    let controller: SnippetController
    let model: SnippetEditorModel
    let box = Box()

    init() throws {
        controller = SnippetController(file: SnippetFile(directory: dir.url))
        for snippet in SampleHistory.snippets.prefix(3) {
            try controller.add(snippet.draft)
        }
        model = SnippetEditorModel(
            controller: controller, environment: SnippetEditorEnvironment(dateFormat: { .hyphen }))
        let box = box
        model.effects = SnippetEditorModel.Effects(
            close: { box.closed += 1 },
            confirmDelete: { name, answer in
                box.asked.append(name)
                answer(box.answer)
            })
    }

    var savedNames: [String] { SnippetFile(directory: dir.url).load().collection.snippets.map(\.name) }

    @Test("開くと先頭を選び、名前・略語・本文を入力欄に出す。指定した定型文を選んで開ける")
    func open() {
        model.open(.open)
        #expect(model.selectedIndex == 0)
        #expect(model.draft.name == "あいさつ（社外）" && model.draft.abbreviation == ";aisatsu")
        #expect(!model.isDirty)
        let third = controller.snippets[2]
        model.open(.edit(third.id))
        #expect(model.selectedSnippet?.id == third.id)
        model.open(.edit(UUID()))
        #expect(model.message?.isError == true)
    }

    @Test("書き換えて保存するとファイルに書く。名前が空なら本文の 1 行目にする")
    func editAndSave() {
        model.open(.open)
        model.draft.name = ""
        model.draft.body = "  \n新しい 1 行目\n2 行目"
        #expect(model.isDirty)
        #expect(model.save())
        #expect(savedNames.first == "新しい 1 行目")
        #expect(model.draft.name == "新しい 1 行目")
        #expect(!model.isDirty)
        #expect(model.message?.isError == false)
    }

    @Test("通らない値は保存せず、理由と入力欄を示す（本文が空・略語に空白）")
    func invalid() {
        model.open(.open)
        model.draft.body = "   "
        #expect(!model.save())
        #expect(model.message?.isError == true)
        #expect(model.focusRequest?.field == .body)
        #expect(SnippetFile(directory: dir.url).load().collection.snippets[0].body.hasPrefix("いつも"))
        model.draft.body = "ok"
        model.draft.abbreviation = "; a"
        #expect(!model.save())
        #expect(model.focusRequest?.field == .abbreviation)
    }

    @Test("ほかを選ぶと変更を自動で保存する。通らなければ選び直さない")
    func autosaveOnSelect() {
        model.open(.open)
        model.draft.abbreviation = ";hello"
        model.select(controller.snippets[1].id)
        #expect(controller.snippets[0].abbreviation == ";hello")
        #expect(model.selectedIndex == 1)
        model.draft.body = ""
        model.select(controller.snippets[0].id)
        #expect(model.selectedIndex == 1)
        #expect(model.message?.isError == true)
    }

    @Test("新しい下書き: 保存で末尾に足す。開いたままなら閉じても保存しない。esc で捨てる")
    func newDraft() {
        model.open(.new(body: "履歴から作った本文"))
        #expect(model.isDraft)
        #expect(model.draftTitle == "履歴から作った本文")
        #expect(!model.isDirty)
        // 手を付けずに閉じると足さない
        model.windowWillClose()
        #expect(savedNames.count == 3)
        model.draft.name = "履歴から"
        model.windowWillClose()
        #expect(savedNames == ["あいさつ（社外）", "今日の日付", "PR の説明テンプレート", "履歴から"])
        #expect(!model.isDraft)

        model.beginNew()
        #expect(model.isDraft && model.focusRequest?.field == .body)
        model.draft.body = "捨てる"
        model.cancel()
        #expect(!model.isDraft && savedNames.count == 4)
        #expect(box.closed == 0)
    }

    @Test("esc: 変更があれば戻し、なければ窓を閉じる")
    func cancel() {
        model.open(.open)
        model.draft.name = "変えた"
        model.cancel()
        #expect(model.draft.name == "あいさつ（社外）")
        #expect(box.closed == 0)
        model.cancel()
        #expect(box.closed == 1)
    }

    @Test("削除は確かめてから。断れば消さない。消したら隣を選ぶ")
    func delete() {
        model.open(.edit(controller.snippets[1].id))
        box.answer = false
        model.deleteSelected()
        #expect(box.asked == ["今日の日付"])
        #expect(savedNames.count == 3)
        box.answer = true
        model.deleteSelected()
        #expect(savedNames == ["あいさつ（社外）", "PR の説明テンプレート"])
        #expect(model.selectedSnippet?.name == "PR の説明テンプレート")
        model.deleteSelected()
        model.deleteSelected()
        #expect(savedNames.isEmpty)
        #expect(model.selection == nil)
        // 0 件で開くと新しい下書きから
        model.open(.open)
        #expect(model.isDraft)
    }

    @Test("並べ替え: 上下に動かすとファイルの順（⌘1〜9 の順）が変わる。端では動かない")
    func reorder() {
        model.open(.edit(controller.snippets[2].id))
        model.moveSelected(by: -1)
        #expect(savedNames == ["あいさつ（社外）", "PR の説明テンプレート", "今日の日付"])
        model.moveSelected(by: -1)
        model.moveSelected(by: -1)
        #expect(savedNames.first == "PR の説明テンプレート")
        #expect(model.selectedIndex == 0)
    }

    @Test("差し込みの札は本文の選択範囲に入る（選んでいた文字は置き換える）")
    func insertPlaceholder() {
        model.beginNew()
        model.draft.body = "こんにちは、さん"
        model.bodySelection = NSRange(location: 6, length: 0)
        model.insert(.clipboard)
        #expect(model.draft.body == "こんにちは、{{クリップボード}}さん")
        #expect(model.bodySelection.location == 6 + "{{クリップボード}}".utf16.count)
        model.bodySelection = NSRange(location: 0, length: 5)
        model.insert(.date)
        #expect(model.draft.body == "{{日付}}、{{クリップボード}}さん")
        // 範囲の外を指していても落ちない
        model.bodySelection = NSRange(location: 999, length: 5)
        model.insert(.cursor)
        #expect(model.draft.body.hasSuffix("さん{{カーソル}}"))
        #expect(model.placeholderSummary(.date, now: SampleHistory.now).contains("2026-10-31"))
    }

    @Test("ほかで書き換えられたら一覧と入力欄に出す。編集中に消されたら新しい下書きとして残す")
    func externalChanges() throws {
        model.open(.open)
        let first = controller.snippets[0]
        try controller.update(id: first.id, with: SnippetDraft(name: "外で変えた", body: "x"))
        #expect(model.draft.name == "外で変えた")
        model.draft.body = "編集中"
        try controller.remove(id: first.id)
        #expect(model.isDraft)
        #expect(model.draft.body == "編集中")
        #expect(model.snippets.count == 2)
    }
}
