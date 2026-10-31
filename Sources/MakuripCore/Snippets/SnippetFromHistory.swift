import Foundation

/// 履歴の項目から定型文の下書きを作るときの本文（純粋関数。一覧の ⇧⌘S）。
///
/// **秘密っぽい項目（`ClipItem.isSecretLikely`）からは作らない**（#25）。定型文の窓は本文を伏せずに出し、
/// 定型文は確度「高」の自動消去・履歴の消去の外にあるため、作ると #19 の「表示のキーを押している間だけ出す」を通らずに平文が残る。
/// 一覧（`HistoryPanelModel.editSnippet`）が先に断るが、本体の側もここを通して同じ決まりを守る
public enum SnippetFromHistory {
    /// 下書きの本文。秘密っぽい項目なら nil（窓を開かない）。項目が消えた・文字がない（画像など）ときは空の下書き
    public static func draftBody(of item: ClipItem?, snapshot: PasteboardSnapshot?) -> String? {
        if item?.isSecretLikely == true { return nil }
        return snapshot.flatMap(KindClassifier.plainText(of:)) ?? ""
    }
}
