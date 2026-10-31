import AppKit
import Foundation
import MakuripCore
import Testing

@testable import MakuripUI

/// 本物のストア（一時フォルダ）を相手にした HistoryActions（AppController と同じ読み方）
@MainActor
final class StoreActions: HistoryActions {
    let store: ClipStore
    init(store: ClipStore) { self.store = store }
    func historyItems(limit: Int) -> [ClipItem] { (try? store.items(limit: limit)) ?? [] }
    func paste(itemID: UUID) {}
    func historyDidClose() {}
    func setPinned(_ pinned: Bool, itemID: UUID) { try? store.setPinned(pinned, id: itemID) }
    func delete(itemID: UUID) { try? store.delete(id: itemID) }
    func representationInfos(itemID: UUID) -> [RepresentationInfo] {
        (try? store.representationInfos(id: itemID)) ?? []
    }
    func representationData(itemID: UUID, itemIndex: Int, type: String) -> Data? {
        try? store.data(id: itemID, itemIndex: itemIndex, type: type)
    }
}

@MainActor
@Suite("中身の遅延読み込み（本物のストア）")
struct ContentLoaderTests {
    func save(_ reps: [[(String, Data)]], to store: ClipStore, at seconds: TimeInterval) throws {
        let snapshot = PasteboardSnapshot(
            items: reps.map {
                PasteboardItemSnapshot(representations: $0.map { PasteboardRepresentation(type: $0.0, data: $0.1) })
            })
        let context = CapturePipeline.Context(
            now: Date(timeIntervalSince1970: seconds),
            frontmostApp: SourceApp(bundleID: "com.example.app", name: "App"),
            copyMethod: .keyboard)
        guard case .accept(let clip) = CapturePipeline.process(snapshot, context: context, limits: .default) else {
            Issue.record("取り込まれなかった")
            return
        }
        _ = try store.save(clip)
    }

    @Test("画像のサムネイル（元の画素数）・ファイル名・全文・色・ピン留め・削除がストアを通って動く")
    func loadsFromStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("makurip-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipStore(directory: directory)
        // 64 KB を超える PNG は blobs/ のファイルに分かれる
        let png = SampleHistory.drawnImage(width: 240, height: 150)
        let padded = png + Data(count: 70_000)  // PNG の後ろの余りは読み飛ばされる
        try save([[(PasteboardTypes.png, padded)]], to: store, at: 10)
        try save(
            [
                [(PasteboardTypes.fileURL, Data("file:///tmp/makurip-sample/a.pdf".utf8))],
                [(PasteboardTypes.fileURL, Data("file:///tmp/makurip-sample/b.txt".utf8))],
            ], to: store, at: 20)
        let long = String(repeating: "長い文章。", count: 500)
        try save([[(PasteboardTypes.utf8PlainText, Data(long.utf8))]], to: store, at: 30)
        try save([[(PasteboardTypes.utf8PlainText, Data("#FF9F0A".utf8))]], to: store, at: 40)

        let actions = StoreActions(store: store)
        let model = HistoryPanelModel(actions: actions)
        model.open()
        #expect(model.items.map(\.kind) == [.color, .text, .file, .image])
        let loader = ClipContentLoader(actions: actions)

        let image = try #require(model.items.first { $0.kind == .image })
        let thumb = await loader.thumbnail(for: image)
        #expect(thumb?.pixelSize == CGSize(width: 240, height: 150))
        #expect(thumb?.format == "PNG")
        #expect(loader.cachedThumbnail(for: image) != nil)

        let files = try #require(model.items.first { $0.kind == .file })
        #expect(loader.cardExtras(for: files).files.map(\.name) == ["a.pdf", "b.txt"])

        let text = try #require(model.items.first { $0.kind == .text })
        let detail = loader.detail(for: text)
        #expect(detail.fullText == long)  // 一覧の平文（先頭 1000 文字）ではなく全文
        #expect(text.previewText?.count == Limits.default.previewCharacterLimit)

        let color = try #require(model.items.first { $0.kind == .color })
        #expect(loader.cardExtras(for: color).color?.hex == "#FF9F0A")

        // ⌘P と ⌘⌫ がストアに届く
        model.select(0)
        #expect(model.handle(KeyStroke(keyCode: 35, modifiers: .command)))
        #expect(try store.item(id: color.id)?.isPinned == true)
        #expect(model.handle(KeyStroke(keyCode: KeyCodes.delete, modifiers: .command)))
        #expect(try store.item(id: color.id) == nil)
        #expect(model.items.count == 3)
    }

    @Test("読めない画像・型のない項目では nil（落ちない）")
    func missingData() async {
        let history = FakeHistory(items: [makeItem(.image, "")], payloads: [:])
        let loader = ClipContentLoader(actions: history)
        #expect(await loader.thumbnail(for: history.items[0]) == nil)
        #expect(ClipContentLoader.decode(Data([1, 2, 3]), type: PasteboardTypes.png, maxPixel: 100) == nil)
    }
}
