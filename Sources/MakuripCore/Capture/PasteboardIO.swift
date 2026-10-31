import AppKit
import UniformTypeIdentifiers

public enum PasteboardReadResult: Sendable {
    /// 除外の印が付いていた（データは読んでいない）
    case excluded
    case snapshot(PasteboardSnapshot, droppedWhileReading: Int)
}

/// ペーストボードの全項目・全型を読む
public enum PasteboardReader {
    /// 古い名前の型（"Pasteboard generator type" 等）は、新しい API では `dyn.` の UTI として見える
    static let legacyExcludedDynamicTypes: Set<String> = {
        let pboardTag = UTTagClass(rawValue: "com.apple.nspboard-type")
        return Set(
            PasteboardMarkers.excluded.compactMap { name in
                UTType(tag: name, tagClass: pboardTag, conformingTo: nil)?.identifier
            })
    }()

    public static func read(_ pasteboard: NSPasteboard, maxRepresentationBytes: Int) -> PasteboardReadResult {
        let items = pasteboard.pasteboardItems ?? []
        // 型名だけで先に除外を判定する（パスワード等のデータそのものを読まないため）
        let typeNames = items.flatMap { $0.types.map(\.rawValue) } + (pasteboard.types ?? []).map(\.rawValue)
        if PasteboardMarkers.containsExcludedMarker(typeNames, extra: legacyExcludedDynamicTypes) {
            return .excluded
        }

        var dropped = 0
        let snapshots = items.map { item in
            var representations: [PasteboardRepresentation] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                if data.count > maxRepresentationBytes {
                    dropped += 1
                    continue
                }
                representations.append(PasteboardRepresentation(type: type.rawValue, data: data))
            }
            return PasteboardItemSnapshot(representations: representations)
        }
        let nonEmpty = snapshots.filter { !$0.representations.isEmpty }
        return .snapshot(PasteboardSnapshot(items: nonEmpty), droppedWhileReading: dropped)
    }
}

/// 候補窓で取り消したときに、貼る前のペーストボードへ戻すための控え
public enum PasteboardStash {
    /// 全項目・全型を読む。除外の印（パスワード等）が付いていても読む（戻せないと取り消しでクリップボードが変わるため）。
    /// **メモリの中だけで持ち、保存も記録もしない**。合計が `maxTotalBytes` を超えたら控えない（nil）
    public static func read(_ pasteboard: NSPasteboard, maxTotalBytes: Int) -> PasteboardSnapshot? {
        var total = 0
        var items: [PasteboardItemSnapshot] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [PasteboardRepresentation] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if total > maxTotalBytes { return nil }
                representations.append(PasteboardRepresentation(type: type.rawValue, data: data))
            }
            if !representations.isEmpty { items.append(PasteboardItemSnapshot(representations: representations)) }
        }
        return PasteboardSnapshot(items: items)
    }
}

/// 保存したものをペーストボードへ書き戻す（全項目・全型を元の順で）
public enum PasteboardWriter {
    /// 書いたあとの changeCount を返す。監視側はこれを `acknowledgeOwnWrite` に渡し、新しい履歴として拾わない
    @discardableResult
    public static func write(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) -> Int {
        let items = snapshot.items.map { itemSnapshot in
            let item = NSPasteboardItem()
            for rep in itemSnapshot.representations {
                item.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.type))
            }
            return item
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        return pasteboard.changeCount
    }
}
