import Foundation

/// 「何をコピーしたか」の判定（純粋関数）。入力はペーストボードの全型とデータ、出力は `ClipKind`。
///
/// 優先順（上で決まったら下は見ない）:
/// 1. ファイル URL（`file://`）があればファイル。Finder のコピーはファイル名の平文とアイコン画像も載せるため最優先
/// 2. 色の型だけがあれば色
/// 3. 平文があれば、その中身で URL → 色の表記 → コマンド → コード を見分ける。どれでもなく
///    リッチテキストの型（RTF/HTML 等）があればリッチテキスト、なければテキスト。
///    ただし画像があって平文が空・URL・パスだけなら画像（ブラウザの「画像をコピー」は画像の URL を平文に載せる）
/// 4. 画像（PDF を含む）があれば画像
/// 5. 平文なしのリッチテキスト・URL の型
/// 6. それ以外はその他
public enum KindClassifier {
    public static func classify(_ snapshot: PasteboardSnapshot) -> ClipKind {
        let types = Set(snapshot.allTypes)
        if containsFileURL(snapshot) { return .file }

        let hasImage = !types.isDisjoint(with: PasteboardTypes.imageTypes) || types.contains(PasteboardTypes.pdf)
        let hasRich = !types.isDisjoint(with: PasteboardTypes.richTextTypes)

        if types.contains(PasteboardTypes.color), !hasImage, !hasRich {
            return .color
        }

        if let text = plainText(of: snapshot), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if hasImage, TextHeuristics.isURL(text) || TextHeuristics.isFilePath(text) {
                return .image
            }
            if TextHeuristics.isURL(text) { return .url }
            if TextHeuristics.isColorLiteral(text) { return .color }
            if TextHeuristics.isCommand(text) { return .command }
            if TextHeuristics.isCode(text) { return .code }
            return hasRich ? .richText : .text
        }

        if hasImage { return .image }
        if hasRich { return .richText }
        if types.contains(PasteboardTypes.url) { return .url }
        return .other
    }

    /// `public.file-url` のうち `file://` で始まるものがあるか
    static func containsFileURL(_ snapshot: PasteboardSnapshot) -> Bool {
        snapshot.items.contains { item in
            guard let data = item.data(for: PasteboardTypes.fileURL),
                let string = String(data: data, encoding: .utf8)
            else { return false }
            return string.hasPrefix("file://")
        }
    }

    /// 最初の項目の平文（UTF-8 / UTF-16 の順に探す）
    public static func plainText(of snapshot: PasteboardSnapshot) -> String? {
        for item in snapshot.items {
            if let data = item.data(for: PasteboardTypes.utf8PlainText) ?? item.data(for: PasteboardTypes.plainText),
                let text = String(data: data, encoding: .utf8)
            {
                return text
            }
            for type in [PasteboardTypes.utf16ExternalPlainText, PasteboardTypes.utf16PlainText] {
                if let data = item.data(for: type), let text = String(data: data, encoding: .utf16) {
                    return text
                }
            }
        }
        return nil
    }

    /// ファイル URL の一覧（ファイルの種類のとき、一覧に名前を出すため）
    public static func fileURLs(of snapshot: PasteboardSnapshot) -> [URL] {
        snapshot.items.compactMap { item in
            guard let data = item.data(for: PasteboardTypes.fileURL),
                let string = String(data: data, encoding: .utf8),
                string.hasPrefix("file://")
            else { return nil }
            return URL(string: string)
        }
    }
}
