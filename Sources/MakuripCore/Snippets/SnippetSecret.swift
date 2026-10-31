import Foundation

/// 定型文の秘密の扱い（#29 L3）。本文か名前に秘密の形の値（`SecretDetector`）があれば秘密っぽいとみなす
/// （AI の口の一覧 `AISnippetTools` と同じ判定）。
///
/// 履歴の秘密と同じく、⌘S のカード・⌘Y・検索は伏せ字にして、表示のキー（既定 ⌥）を押している間だけ本当の値を出す。
/// 貼るときは ConcealedType の印を足す（`SnippetPaste.snapshot(for:)`）。定型文は人が登録したものなので、
/// 自動では消さない（消すのは定型文の窓から）。定型文の窓は編集の場なので、選んだ定型文の本文は伏せない
extension Snippet {
    public var isSecretLikely: Bool {
        !SecretDetector.findings(in: body).isEmpty || !SecretDetector.findings(in: name).isEmpty
    }

    /// 一覧・⌘Y・検索に使う写し。名前・略語・本文の秘密の値を伏せ字にする（貼るときは使わない）
    public var masked: Snippet {
        var copy = self
        copy.name = SecretMask.masked(name).text
        copy.abbreviation = SecretMask.masked(abbreviation).text
        copy.body = SecretMask.masked(body).text
        return copy
    }

    /// 秘密っぽい定型文の検索の文字列。伏せ字の写しから作り、「秘密」「ひみつ」を足す（履歴の秘密と同じく、中身では引けない）
    public var maskedSearchHaystack: String {
        masked.searchHaystack + "\n" + SearchText.normalize("秘密 ひみつ")
    }
}
