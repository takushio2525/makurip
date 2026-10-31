import AppKit
import Foundation
import Testing

@testable import MakuripCore

/// 一意な名前の private ペーストボード。一般ペーストボード（ユーザーの本物）には触らない
final class PrivatePasteboard {
    let pasteboard: NSPasteboard

    init() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.takushio2525.makurip.tests.\(UUID().uuidString)"))
    }

    deinit {
        pasteboard.releaseGlobally()
    }

    func write(_ items: [[(String, Data)]]) {
        _ = PasteboardWriter.write(Fixtures.items(items), to: pasteboard)
    }
}

@Suite("ペーストボードの読み書きと監視（private ペーストボード）")
@MainActor
struct PasteboardRoundTripTests {
    @Test("全項目・全型を書いて読むと元どおり（アプリ独自の型を含む）")
    func roundTrip() {
        let board = PrivatePasteboard()
        var reps: [(String, Data)] = [
            (PasteboardTypes.utf8PlainText, Data("Makurip".utf8)), (PasteboardTypes.rtf, Fixtures.rtfBytes),
            (PasteboardTypes.html, Fixtures.htmlBytes),
        ]
        for i in 0..<40 { reps.append(("com.takushio2525.makurip.tests.type-\(i)", Data("v\(i)".utf8))) }
        let snapshot = Fixtures.items([reps, [(PasteboardTypes.png, Fixtures.pngBytes)]])
        PasteboardWriter.write(snapshot, to: board.pasteboard)

        guard
            case .snapshot(let read, let dropped) = PasteboardReader.read(
                board.pasteboard, maxRepresentationBytes: 1 << 20)
        else {
            Issue.record("除外された")
            return
        }
        #expect(dropped == 0)
        // 書いた型はすべて同じデータで、同じ順に残る。ペーストボードは UTF-8 の平文から
        // public.utf16-external-plain-text を自動で足して返すので、足された型は許す
        #expect(read.items.count == snapshot.items.count)
        for (written, got) in zip(snapshot.items, read.items) {
            #expect(got.types.filter { written.types.contains($0) } == written.types)
            for rep in written.representations { #expect(got.data(for: rep.type) == rep.data) }
        }

        // 読んだものを書き戻してもう一度読むと同じ（何度貼り直しても変わらない）
        PasteboardWriter.write(read, to: board.pasteboard)
        guard case .snapshot(let reread, _) = PasteboardReader.read(board.pasteboard, maxRepresentationBytes: 1 << 20)
        else {
            Issue.record("除外された")
            return
        }
        #expect(reread == read)
        #expect(ContentHasher.hash(reread) == ContentHasher.hash(read))
    }

    @Test("ConcealedType はデータを読まずに除外する")
    func concealedExcluded() {
        let board = PrivatePasteboard()
        PasteboardWriter.write(Fixtures.concealed, to: board.pasteboard)
        guard case .excluded = PasteboardReader.read(board.pasteboard, maxRepresentationBytes: 1 << 20) else {
            Issue.record("除外されなかった")
            return
        }
    }

    @Test("読む段階で上限を超える型を落とす")
    func readLimit() {
        let board = PrivatePasteboard()
        board.write([[(PasteboardTypes.tiff, Data(count: 2000)), (PasteboardTypes.png, Data(count: 10))]])
        guard
            case .snapshot(let read, let dropped) = PasteboardReader.read(
                board.pasteboard, maxRepresentationBytes: 1000)
        else {
            Issue.record("除外された")
            return
        }
        #expect(dropped == 1)
        #expect(read.allTypes == [PasteboardTypes.png])
    }

    @Test("監視: 起動前の中身は取り込まず、変化を取り込む。書き戻しは新しい履歴にしない")
    func monitor() throws {
        let dir = TemporaryDirectory()
        let store = try ClipStore(directory: dir.url)
        let board = PrivatePasteboard()
        board.write([[(PasteboardTypes.utf8PlainText, Data("before start".utf8))]])

        var keyMonitorActive = true
        let monitor = PasteboardMonitor(
            pasteboard: board.pasteboard, store: store, limits: .default,
            environment: .init(
                now: { Date() }, frontmostApp: { SourceApp(bundleID: "com.example.front", name: "Front") },
                keyMonitorActive: { keyMonitorActive }), settleDelay: 0)
        #expect(monitor.poll() == nil)
        #expect(try store.count() == 0)

        // ボタン等（⌘C なし）
        board.write([[(PasteboardTypes.utf8PlainText, Data("button copy".utf8))]])
        guard case .saved(.inserted(let buttonID), .text, .other, _, _) = monitor.poll() else {
            Issue.record("取り込まれなかった")
            return
        }

        // ⌘C を見た直後
        monitor.noteCopyShortcut(
            CopyShortcutSignal(at: Date(), frontmostApp: SourceApp(bundleID: "com.example.editor", name: "Editor")))
        board.write([[(PasteboardTypes.utf8PlainText, Data("git status".utf8))]])
        guard case .saved(.inserted(let keyID), .command, .keyboard, _, _) = monitor.poll() else {
            Issue.record("キー操作として取り込まれなかった")
            return
        }
        #expect(try store.item(id: keyID)?.source?.bundleID == "com.example.editor")

        // 使った ⌘C は次の変化に持ち越さない
        board.write([[(PasteboardTypes.utf8PlainText, Data("next".utf8))]])
        guard case .saved(_, _, .other, _, _) = monitor.poll() else {
            Issue.record("2 回目もキー操作になった")
            return
        }

        // 書き戻し: 新しい履歴にせず、件数は変わらない
        let before = try store.count()
        let snapshot = try #require(try store.snapshot(id: buttonID))
        monitor.acknowledgeOwnWrite(changeCount: PasteboardWriter.write(snapshot, to: board.pasteboard))
        try store.touch(id: buttonID)
        #expect(monitor.poll() == nil)
        #expect(try store.count() == before)
        #expect(try store.items().first?.id == buttonID)

        // 一時停止中の変化は、再開後も取り込まない
        monitor.setPaused(true)
        board.write([[(PasteboardTypes.utf8PlainText, Data("while paused".utf8))]])
        #expect(monitor.poll() == .skipped(.paused))
        monitor.setPaused(false)
        #expect(monitor.poll() == nil)
        #expect(try store.count() == before)

        // キー監視が効いていないときは不明
        keyMonitorActive = false
        board.write([[(PasteboardTypes.utf8PlainText, Data("unknown method".utf8))]])
        guard case .saved(_, _, .unknown, _, _) = monitor.poll() else {
            Issue.record("不明にならなかった")
            return
        }

        // 空の変化・除外の印
        board.pasteboard.clearContents()
        #expect(monitor.poll() == .skipped(.empty))
        PasteboardWriter.write(Fixtures.concealed, to: board.pasteboard)
        #expect(monitor.poll() == .skipped(.excludedMarker))
    }

    @Test("同じ内容を続けてコピーしても 1 件のまま")
    func duplicateCopies() throws {
        let dir = TemporaryDirectory()
        let store = try ClipStore(directory: dir.url)
        let board = PrivatePasteboard()
        let monitor = PasteboardMonitor(
            pasteboard: board.pasteboard, store: store, limits: .default,
            environment: .init(now: { Date() }, frontmostApp: { nil }, keyMonitorActive: { true }), settleDelay: 0)
        for _ in 0..<5 {
            board.write([[(PasteboardTypes.utf8PlainText, Data("repeat".utf8))]])
            monitor.poll()
        }
        #expect(try store.count() == 1)
        #expect(try store.items().first?.copyCount == 5)
    }

    @Test("書き込みの途中（clearContents のあと項目を足している最中）に見つけても、全項目が揃ってから取り込む")
    func settlesBeforeCapture() async throws {
        let dir = TemporaryDirectory()
        let store = try ClipStore(directory: dir.url)
        let board = PrivatePasteboard()
        var events: [PasteboardMonitor.Event] = []
        let monitor = PasteboardMonitor(
            pasteboard: board.pasteboard, store: store, limits: .default,
            environment: .init(now: { Date() }, frontmostApp: { nil }, keyMonitorActive: { true }), settleDelay: 0.05)
        monitor.onEvent = { events.append($0) }

        // 1 項目目だけ書いた瞬間に見つける
        board.pasteboard.clearContents()
        let first = NSPasteboardItem()
        first.setString("part 1", forType: .string)
        board.pasteboard.writeObjects([first])
        #expect(monitor.poll() == nil)

        // changeCount を増やさずに残りの項目が足される
        let second = NSPasteboardItem()
        second.setString("part 2", forType: .string)
        board.pasteboard.writeObjects([second])

        // 0.05 秒後の確かめはメインのキューで走る。ほかのテストやマシンが混んでいるとメインが遅れるので、決まった時間でなく条件で待つ
        #expect(await waitUntil(timeout: 3) { events.count == 1 })
        #expect(events.count == 1)
        let item = try #require(try store.items().first)
        #expect(item.pasteboardItemCount == 2)
    }
}
