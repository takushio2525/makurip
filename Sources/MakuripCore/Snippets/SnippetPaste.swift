import Foundation

/// `{{クリップボード}}` と `{{言語}}` に使う履歴の選び方（純粋関数）。
///
/// 試作と同じく「履歴のいちばん新しい文字」を使う（いまのペーストボードを直接は読まない）。
/// 記録しなかったコピー（パスワード管理アプリ・記録しないアプリ・一時停止中）と、秘密っぽい項目（`secretLikely`）を
/// 定型文に混ぜて貼らないため
public enum SnippetClipboard {
    /// 文字として差し込める種類（画像・ファイル・その他は飛ばす）
    static let textualKinds: Set<ClipKind> = [.text, .richText, .code, .command, .url, .color]

    /// 新しい順の履歴から、差し込みに使う 1 件
    public static func source(in items: [ClipItem]) -> ClipItem? {
        candidates(in: items).first
    }

    /// 差し込みに使える項目（新しい順）。先頭の文字が読めなければ（色の型だけ等）次を見るのに使う
    public static func candidates(in items: [ClipItem]) -> [ClipItem] {
        items.filter { textualKinds.contains($0.kind) && !$0.flags.contains(.secretLikely) }
    }

    /// `{{言語}}` の言語。コードは中身から判定し、コマンドはシェル。文章などは nil（空にする）
    public static func language(of text: String, kind: ClipKind) -> CodeLanguage? {
        switch kind {
        case .command: .shell
        case .code: CodeLanguageDetector.detect(text)
        default: nil
        }
    }
}

/// 定型文を貼るときにペーストボードへ書く中身（純粋関数）
public enum SnippetPaste {
    /// 置き換えた文字を、文字の型（UTF-8）だけで書く。プレーンテキストで貼るときも同じ（書式を持たないため）。
    /// 秘密の形の値を含むときは ConcealedType の印を足す（ほかのクリップボード履歴アプリに記録させない。
    /// 履歴の秘密を貼るとき `PastePipeline.prepare(…, secret: true)` と同じ。#29 L3）
    public static func snapshot(for text: String) -> PasteboardSnapshot {
        let snapshot = PasteboardSnapshot(items: [
            PasteboardItemSnapshot(representations: [
                PasteboardRepresentation(type: PasteboardTypes.utf8PlainText, data: Data(text.utf8))
            ])
        ])
        return SecretDetector.findings(in: text).isEmpty ? snapshot : PastePipeline.markedConcealed(snapshot)
    }

    /// `{{カーソル}}` の位置へ文字カーソルを動かす先。**貼る前と後の入力欄を AX で読めて、
    /// 文字カーソルがちょうど貼った文字の後ろにあるときだけ**返す（そうでなければ動かさない。nil）。
    ///
    /// 改行の変換・自動の字下げなどで貼った長さが変わるアプリでは、位置が合わないので動かさない
    public static func cursorTarget(
        before: TextProbe?, after: TextProbe?, insertedLength: Int, offsetFromEnd: Int?
    ) -> AXTextRange? {
        guard let offsetFromEnd, offsetFromEnd > 0, let before, let after, after.selectionSettable,
            before.selection.location >= 0, after.selection.length == 0
        else { return nil }
        let end = before.selection.location + insertedLength
        guard after.selection.location == end, end - offsetFromEnd >= before.selection.location else { return nil }
        return AXTextRange(location: end - offsetFromEnd, length: 0)
    }
}
