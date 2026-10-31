import Foundation
import Testing

@testable import MakuripCore

@Suite("キーマップ")
struct KeymapTests {
    @Test("既定のキーに重なりがない")
    func noConflicts() {
        #expect(Keymap.default.conflicts().isEmpty)
    }

    @Test("全操作が ID・既定のキー・説明文を持つ。ID は重ならない")
    func everyActionIsDescribed() {
        for action in KeyAction.allCases {
            #expect(!action.rawValue.isEmpty)
            #expect(!action.label.isEmpty)
            #expect(!action.summary.isEmpty)
            #expect(!action.group.isEmpty)
            #expect(!action.defaultCombos.isEmpty, "\(action) に既定のキーがない")
        }
        #expect(Set(KeyAction.allCases.map(\.rawValue)).count == KeyAction.allCases.count)
    }

    @Test("ID と並びは試作（core.js の Mk.ACTIONS）と同じ")
    func prototypeIDs() {
        let ids = KeyAction.allCases.map(\.rawValue)
        #expect(
            ids == [
                "open", "openList", "close", "prev", "next", "paste", "pastePlain", "copyOnly", "quick", "kindNext",
                "kindPrev", "method", "app", "pinned", "pin", "look", "reveal", "source", "delete", "settings",
                "candUp",
                "candDown",
                "candCommit", "candCancel", "candExpand",
            ])
    }

    @Test("候補窓のキーは候補窓の範囲で引く（↑↓・Tab と Enter で確定・esc・⌃⌘V で広げる）")
    func candidateKeys() {
        let map = Keymap.default
        func action(_ code: UInt16, _ modifiers: HotKey.Modifiers = []) -> KeyAction? {
            map.action(for: KeyStroke(keyCode: code, modifiers: modifiers), scope: .candidate)?.action
        }
        #expect(action(KeyCodes.upArrow) == .candidateUp)
        #expect(action(KeyCodes.downArrow) == .candidateDown)
        #expect(action(KeyCodes.tab) == .candidateCommit)
        #expect(action(KeyCodes.returnKey) == .candidateCommit)
        #expect(action(KeyCodes.keypadEnter) == .candidateCommit)
        #expect(action(KeyCodes.escape) == .candidateCancel)
        #expect(action(9, [.control, .command]) == .candidateExpand)
        #expect(action(0) == nil)  // 文字のキーは候補窓のキーではない（確定して素通し）
        #expect(action(KeyCodes.upArrow, .shift) == nil)
        // 一覧を開くキーは全体の範囲
        #expect(
            map.action(for: KeyStroke(keyCode: 9, modifiers: [.control, .option, .command]), scope: .global)?.action
                == .openList)
        // パネルの範囲では候補窓のキーを引かない
        #expect(map.action(for: KeyStroke(keyCode: KeyCodes.upArrow))?.action == .previous)
    }

    @Test("候補窓のキーは候補窓のキーどうしだけ比べる（⌃⌘V が「呼び出す」と「広げる」の両方にあっても重なりではない）")
    func candidateScopeConflicts() {
        #expect(Keymap.default.conflicts().isEmpty)
        var map = Keymap.default
        map.set([KeyCombo(.code(KeyCodes.escape))], for: .candidateCommit)  // 確定と取り消しが同じ esc
        let conflicts = map.conflicts()
        #expect(conflicts.count == 1)
        #expect(Set([conflicts[0].first, conflicts[0].second]) == [.candidateCommit, .candidateCancel])

        var openList = Keymap.default
        openList.set([KeyCombo(.code(9), [.control, .command])], for: .openList)  // 呼び出す と 一覧を開く が同じ
        #expect(openList.conflicts().count == 1)
    }

    @Test("押したキーから操作を引く")
    func lookup() {
        let map = Keymap.default
        func action(_ code: UInt16, _ modifiers: HotKey.Modifiers = []) -> KeyAction? {
            map.action(for: KeyStroke(keyCode: code, modifiers: modifiers))?.action
        }
        #expect(action(KeyCodes.upArrow) == .previous)
        #expect(action(35, .control) == .previous)  // ⌃P
        #expect(action(KeyCodes.downArrow) == .next)
        #expect(action(45, .control) == .next)  // ⌃N
        #expect(action(KeyCodes.returnKey) == .paste)
        #expect(action(KeyCodes.keypadEnter) == .paste)
        #expect(action(KeyCodes.returnKey, .shift) == .pastePlain)
        #expect(action(KeyCodes.returnKey, .command) == .copyOnly)
        #expect(action(KeyCodes.escape) == .close)
        #expect(action(KeyCodes.tab) == .kindNext)
        #expect(action(KeyCodes.tab, .shift) == .kindPrevious)
        #expect(action(40, .command) == .cycleMethod)  // ⌘K
        #expect(action(14, .command) == .chooseApp)  // ⌘E
        #expect(action(35, [.command, .shift]) == .pinnedOnly)  // ⌘⇧P
        #expect(action(35, .command) == .togglePin)  // ⌘P
        #expect(action(16, .command) == .preview)  // ⌘Y
        #expect(action(KeyCodes.delete, .command) == .delete)
        // 修飾キーが違えば当たらない（文字の入力は検索欄へ流す）
        #expect(action(40) == nil)  // K
        #expect(action(35) == nil)  // P
        #expect(action(KeyCodes.delete) == nil)  // ⌫ は検索欄の 1 文字削除
        // 全体のキーはパネルの範囲では引かない
        #expect(action(9, [.control, .command]) == nil)
        #expect(
            map.action(for: KeyStroke(keyCode: 9, modifiers: [.control, .command]), scope: .global)?.action
                == .openHistory)
    }

    @Test("⌘1〜9 は押した番号を返す")
    func digits() {
        for (index, code) in KeyCodes.digitCodes.enumerated() {
            let hit = Keymap.default.action(for: KeyStroke(keyCode: code, modifiers: .command))
            #expect(hit?.action == .quickPaste)
            #expect(hit?.digit == index + 1)
        }
        #expect(Keymap.default.action(for: KeyStroke(keyCode: 29, modifiers: .command)) == nil)  // ⌘0
        #expect(Keymap.default.action(for: KeyStroke(keyCode: 18)) == nil)  // 1 だけは文字の入力
    }

    @Test("重なりを見つける（同じキー・数字の範囲と数字のキー・テンキーの Enter）")
    func detectsConflicts() {
        var map = Keymap.default
        map.set([KeyCombo(.code(16), .command)], for: .togglePin)  // ⌘Y を「ピン留め」にも
        let conflicts = map.conflicts()
        #expect(conflicts.count == 1)
        #expect(Set([conflicts[0].first, conflicts[0].second]) == [.preview, .togglePin])

        var digits = Keymap.default
        digits.set([KeyCombo(.code(19), .command)], for: .preview)  // ⌘2 と ⌘1–9
        #expect(digits.conflicts().count == 1)

        var enter = Keymap.default
        enter.set([KeyCombo(.code(KeyCodes.keypadEnter))], for: .preview)  // テンキーの Enter と Return
        #expect(enter.conflicts().count == 1)

        var global = Keymap.default
        global.set([KeyCombo(.code(9), [.control, .command])], for: .preview)  // 呼び出しキーと同じ
        #expect(global.conflicts().count == 1)
    }

    @Test("表記は試作と同じ（修飾キーは ⌃⌥⇧⌘ の順。試作の comboText も ⇧⌘P と出す）")
    func display() {
        let map = Keymap.default
        #expect(map.primary(.cycleMethod)?.displayString == "⌘K")
        #expect(map.primary(.kindNext)?.displayString == "⇥")
        #expect(map.primary(.kindPrevious)?.displayString == "⇧⇥")
        #expect(map.primary(.quickPaste)?.displayString == "⌘1–9")
        #expect(map.primary(.close)?.displayString == "esc")
        #expect(map.primary(.pinnedOnly)?.displayString == "⇧⌘P")
        #expect(map.primary(.delete)?.displayString == "⌘⌫")
        #expect(map.primary(.openHistory)?.displayString == "⌃⌘V")
        #expect(map.primary(.openList)?.displayString == "⌃⌥⌘V")
        #expect(map.primary(.openList)?.hotKey == .defaultOpenList)
        #expect(map.primary(.candidateExpand)?.displayString == "⌃⌘V")
        #expect(map.primary(.paste)?.isReturn == true)
        #expect(map.primary(.openHistory)?.hotKey == .defaultOpenHistory)
        #expect(map.primary(.quickPaste)?.hotKey == nil)
    }

    @Test("プレーンテキストで貼る説明文は、コマンドのプロンプトを外さないことを書く（PastePipeline の振る舞いと合わせる）")
    func plainPasteSummaryMentionsPrompt() {
        #expect(KeyAction.pastePlain.summary.contains("プロンプト"))
        #expect(KeyAction.pastePlain.summary.contains("外さず"))
    }
}
