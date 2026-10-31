import Foundation

/// ペーストボードの 1 つの型とそのデータの組（例: `public.png` と PNG のバイト列）
public struct PasteboardRepresentation: Sendable, Hashable {
    /// UTI（`public.utf8-plain-text` 等）。アプリ独自の型（`dyn.` や `com.example.x`）もそのまま持つ
    public var type: String
    public var data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

/// NSPasteboardItem 1 つ分。持っている型を、ペーストボードが返した順（= 書き手の優先順）に並べる
public struct PasteboardItemSnapshot: Sendable, Hashable {
    public var representations: [PasteboardRepresentation]

    public init(representations: [PasteboardRepresentation]) {
        self.representations = representations
    }

    public var types: [String] { representations.map(\.type) }

    public func data(for type: String) -> Data? {
        representations.first { $0.type == type }?.data
    }
}

/// 1 回のコピーでペーストボードに載った全項目・全型。貼り直すとき元どおりにするための単位
public struct PasteboardSnapshot: Sendable, Hashable {
    public var items: [PasteboardItemSnapshot]

    public init(items: [PasteboardItemSnapshot]) {
        self.items = items
    }

    public var totalBytes: Int {
        items.reduce(0) { sum, item in sum + item.representations.reduce(0) { $0 + $1.data.count } }
    }

    /// 全項目の型（重複なし・初出順）
    public var allTypes: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for type in items.flatMap(\.types) where seen.insert(type).inserted {
            result.append(type)
        }
        return result
    }

    public var isEmpty: Bool {
        items.allSatisfy { $0.representations.isEmpty }
    }

    /// 最初に見つかったその型のデータ（項目をまたいで探す）
    public func firstData(for type: String) -> Data? {
        for item in items {
            if let data = item.data(for: type) { return data }
        }
        return nil
    }
}
