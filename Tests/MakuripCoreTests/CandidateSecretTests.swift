import CoreGraphics
import Foundation
import Testing

@testable import MakuripCore

/// 候補窓で、秘密っぽい項目は仮に貼らず、確定したときに初めて貼る（試作どおり）
@MainActor
@Suite("候補窓と秘密")
struct CandidateSecretTests {
    static let secretText = "sk-test-0000"
    static let flags: Set<ClipFlag> = [.secretLikely, .secretKnownFormat]

    /// 指定した位置の項目を秘密にした候補窓
    func harness(secretAt indices: Set<Int>, items: [(ClipKind, FakeContent)]? = nil) -> CandidateHarness {
        let h = CandidateHarness(
            items: items ?? [(.text, .text("最新")), (.text, .text(Self.secretText)), (.code, .text("let x = 1"))])
        for index in indices { h.host.items[index].flags = Self.flags }
        return h
    }

    @Test("最新が秘密なら、始めても仮に貼らない（窓だけ出して横取りする）")
    func latestSecretNotPasted() async {
        let h = harness(secretAt: [0], items: [(.text, .text(Self.secretText)), (.text, .text("ふつう"))])
        #expect(h.coordinator.start() == .started)
        await h.coordinator.waitUntilIdle()
        #expect(h.editor.string == "メモ：")
        #expect(!h.host.sent.contains(.paste))
        #expect(h.tap.isActive)
        #expect(h.presenter.last?.selectedItem?.isSecretLikely == true)
        #expect(h.coordinator.debugState["selectedSecret"] == "true")
    }

    @Test("↑ で秘密に来たら仮に貼ったものを戻し、秘密は貼らない。さらに ↑ で次の項目を貼る")
    func movingOntoSecretRemovesTentative() async {
        let h = harness(secretAt: [1])
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        #expect(h.editor.string == "メモ：最新")
        h.tap.press(KeyCodes.upArrow)
        await h.coordinator.waitUntilIdle()
        #expect(h.editor.string == "メモ：", "秘密を選んでいる間は文書に何も入れない")
        #expect(!h.editor.string.contains(Self.secretText))
        h.tap.press(KeyCodes.upArrow)
        await h.coordinator.waitUntilIdle()
        #expect(h.editor.string == "メモ：let x = 1")
    }

    @Test("確定（Tab）したときに初めて秘密を貼り、先頭へ移す")
    func commitPastesSecret() async {
        let h = harness(secretAt: [1])
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        h.tap.press(KeyCodes.upArrow)
        await h.coordinator.waitUntilIdle()
        #expect(h.tap.press(KeyCodes.tab) == .consume)
        await h.coordinator.waitUntilIdle()
        #expect(h.editor.string == "メモ：\(Self.secretText)")
        #expect(h.host.used == [h.id(1)])
        h.expectClosed()
    }

    @Test("秘密に移ってすぐ確定しても、前に仮に貼ったものは残らない")
    func commitImmediatelyAfterMoving() async {
        let h = harness(secretAt: [1])
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        // 差し替えを待たずに確定する
        h.tap.press(KeyCodes.upArrow)
        h.tap.press(KeyCodes.returnKey)
        await h.coordinator.waitUntilIdle()
        #expect(h.editor.string == "メモ：\(Self.secretText)")
        h.expectClosed()
    }

    @Test("秘密を選んだまま、ほかのキー・窓の外のクリック・無操作で閉じたら、秘密は貼らずに元へ戻す")
    func implicitCloseDoesNotPasteSecret() async {
        for close in ["otherKey", "click", "idle"] {
            let h = harness(secretAt: [1])
            h.coordinator.start()
            await h.coordinator.waitUntilIdle()
            h.tap.press(KeyCodes.upArrow)
            await h.coordinator.waitUntilIdle()
            switch close {
            case "otherKey": #expect(h.tap.press(0) == .pass)  // A
            case "click": h.tap.send(.mouseDown(CGPoint(x: 10, y: 10)))
            default: h.scheduler.fireAll()
            }
            await h.coordinator.waitUntilIdle()
            #expect(h.editor.string == "メモ：", "\(close) で秘密が貼られた")
            #expect(h.editor.pasteboard == .text("元のクリップボード"), "\(close) でクリップボードが戻らない")
            #expect(h.host.used.isEmpty)
            h.expectClosed()
        }
    }

    @Test("確定まで貼らないアプリ（ターミナル等）でも、秘密は確定したときに貼る")
    func deferredAppCommit() async {
        let h = CandidateHarness(
            items: [(.text, .text(Self.secretText)), (.text, .text("ふつう"))], bundleID: "com.apple.Terminal")
        h.host.items[0].flags = Self.flags
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        #expect(h.coordinator.method == .deferred)
        h.tap.press(KeyCodes.tab)
        await h.coordinator.waitUntilIdle()
        #expect(h.editor.string == "メモ：\(Self.secretText)")
    }

    @Test("表示のキー（既定 ⌥）を押している間だけ表示の状態にし、修飾キーは食べない")
    func revealWhileHeld() async {
        let h = harness(secretAt: [1])
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        #expect(h.presenter.last?.revealed == false)
        #expect(h.tap.send(.flagsChanged(.option)) == .pass)
        #expect(h.presenter.last?.revealed == true)
        #expect(h.coordinator.isActive, "修飾キーだけでは閉じない")
        #expect(h.tap.send(.flagsChanged([])) == .pass)
        #expect(h.presenter.last?.revealed == false)
        // ⌥ と一緒に別の修飾キーを押していても表示する
        h.tap.send(.flagsChanged([.option, .shift]))
        #expect(h.presenter.last?.revealed == true)
        // 閉じたら隠した状態に戻り、次に始めたときも隠している
        h.tap.press(KeyCodes.escape)
        await h.coordinator.waitUntilIdle()
        #expect(!h.coordinator.revealed)
        h.coordinator.start()
        #expect(h.presenter.last?.revealed == false)
        h.coordinator.cancel()
        await h.coordinator.waitUntilIdle()
    }

    @Test("表示のキーを付け替えたら、そのキーで表示する")
    func revealKeyFollowsKeymap() async {
        let h = harness(secretAt: [1])
        var keymap = Keymap.default
        keymap.set([KeyCombo(.hold, .command)], for: .reveal)
        h.coordinator.keymap = keymap
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        h.tap.send(.flagsChanged(.option))
        #expect(h.presenter.last?.revealed == false)
        h.tap.send(.flagsChanged(.command))
        #expect(h.presenter.last?.revealed == true)
        h.coordinator.cancel()
        await h.coordinator.waitUntilIdle()
    }
}
