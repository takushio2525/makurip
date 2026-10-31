import Foundation

@testable import MakuripCore

/// テスト用の入力例。すべて自作のデータ（実際のクリップボードの中身は使わない）
enum Fixtures {
    static func text(_ string: String, extra: [(String, Data)] = []) -> PasteboardSnapshot {
        item([(PasteboardTypes.utf8PlainText, Data(string.utf8))] + extra)
    }

    static func item(_ reps: [(String, Data)]) -> PasteboardSnapshot {
        PasteboardSnapshot(items: [
            PasteboardItemSnapshot(representations: reps.map { PasteboardRepresentation(type: $0.0, data: $0.1) })
        ])
    }

    static func items(_ items: [[(String, Data)]]) -> PasteboardSnapshot {
        PasteboardSnapshot(
            items: items.map { reps in
                PasteboardItemSnapshot(representations: reps.map { PasteboardRepresentation(type: $0.0, data: $0.1) })
            })
    }

    /// 1x1 の PNG（ヘッダだけ本物らしくした合成データ。判定は型名で行うので中身は問わない）
    static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01, 0x02])
    static let tiffBytes = Data([0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08])
    static let rtfBytes = Data(#"{\rtf1\ansi {\b Makurip} test}"#.utf8)
    static let htmlBytes = Data("<b>Makurip</b> test".utf8)

    static let rtf = text("Makurip test", extra: [(PasteboardTypes.rtf, rtfBytes)])
    static let png = item([(PasteboardTypes.png, pngBytes)])

    /// Finder でファイルをコピーしたときの形（ファイル URL・名前の平文・アイコン画像）
    static let finderFile = item([
        (PasteboardTypes.fileURL, Data("file:///tmp/makurip-test/report.pdf".utf8)),
        (PasteboardTypes.utf8PlainText, Data("report.pdf".utf8)),
        ("com.apple.icns", Data([0x69, 0x63, 0x6E, 0x73])),
        (PasteboardTypes.tiff, tiffBytes),
    ])

    static let color = item([(PasteboardTypes.color, Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74]))])

    /// パスワード管理アプリの形（中身は合成。ConcealedType の印付き）
    static let concealed = item([
        (PasteboardTypes.utf8PlainText, Data("not-a-real-secret".utf8)),
        (PasteboardMarkers.concealed, Data()),
    ])
}
