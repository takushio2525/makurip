import Foundation
import Testing

@testable import MakuripCore

@Suite("型 1 つの読み出しと、文字だけの写し")
struct StoreReadTests {
    @Test("型 1 つのデータを読める（DB の中・blobs/ のファイルとも）")
    func readSingleType() throws {
        let dir = TemporaryDirectory()
        let store = try ClipStore(directory: dir.url)
        let big = Data(repeating: 0x42, count: Limits.default.inlineThresholdBytes + 10)
        let snapshot = Fixtures.items([
            [(PasteboardTypes.utf8PlainText, Data("one".utf8)), (PasteboardTypes.png, big)],
            [(PasteboardTypes.utf8PlainText, Data("two".utf8))],
        ])
        let id = try store.save(makeClip(snapshot, at: 10)).id
        #expect(try store.data(id: id, itemIndex: 0, type: PasteboardTypes.utf8PlainText) == Data("one".utf8))
        #expect(try store.data(id: id, itemIndex: 1, type: PasteboardTypes.utf8PlainText) == Data("two".utf8))
        #expect(try store.data(id: id, itemIndex: 0, type: PasteboardTypes.png) == big)
        #expect(try store.data(id: id, itemIndex: 1, type: PasteboardTypes.png) == nil)
        #expect(try store.data(id: UUID(), itemIndex: 0, type: PasteboardTypes.png) == nil)
    }

    @Test("プレーンテキストで貼るときは文字の型だけを残す")
    func plainTextOnly() {
        #expect(Fixtures.rtf.plainTextOnly()?.allTypes == [PasteboardTypes.utf8PlainText])
        #expect(Fixtures.png.plainTextOnly() == nil)
    }
}
