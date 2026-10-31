import Foundation

/// 1 回のコピー（全項目・全型）について、秘密っぽいかを決めた結果。中身は持たない
public struct SecretAssessment: Sendable, Hashable {
    public var confidence: SecretConfidence
    /// 当たった形式（ログに数だけ出す。画面の理由は表示のときに全文から決め直す）
    public var kinds: Set<SecretKind>

    public init(confidence: SecretConfidence, kinds: Set<SecretKind>) {
        self.confidence = confidence
        self.kinds = kinds
    }

    /// 履歴に付ける印。確度が高いものだけ自動消去の対象（`secretKnownFormat`）
    public var flags: Set<ClipFlag> {
        confidence == .high ? [.secretLikely, .secretKnownFormat] : [.secretLikely]
    }
}

/// ペーストボードのスナップショットから、判定に使う文字を集めて `SecretDetector` に通す（純粋関数）
public enum SecretScanner {
    /// 判定に使う型（平文・ファイルの URL・平文がないときのリッチテキスト）。既存の履歴に当て直すとき、画像を読まずに済むように
    public static let textTypes: Set<String> = [
        PasteboardTypes.utf8PlainText, PasteboardTypes.plainText, PasteboardTypes.utf16PlainText,
        PasteboardTypes.utf16ExternalPlainText, PasteboardTypes.fileURL, PasteboardTypes.url, PasteboardTypes.rtf,
        PasteboardTypes.html,
    ]

    public static func assess(_ snapshot: PasteboardSnapshot) -> SecretAssessment? {
        var kinds: Set<SecretKind> = []
        for text in texts(of: snapshot) {
            for finding in SecretDetector.findings(in: text) { kinds.insert(finding.kind) }
        }
        guard let confidence = kinds.map(\.confidence).max() else { return nil }
        return SecretAssessment(confidence: confidence, kinds: kinds)
    }

    /// 判定に使う文字。項目ごとの平文と、ファイル・URL の文字列。どの項目にも平文がなければ RTF・HTML の中身をそのまま
    /// （秘密の値は RTF・HTML の中でもそのままの綴りで入っている。制御語やタグは判定の邪魔にならない）
    static func texts(of snapshot: PasteboardSnapshot) -> [String] {
        var result: [String] = []
        var hasPlainText = false
        for item in snapshot.items {
            if let text = plainText(of: item) {
                result.append(text)
                hasPlainText = true
            }
            for type in [PasteboardTypes.fileURL, PasteboardTypes.url] {
                guard let data = item.data(for: type), let string = String(data: data, encoding: .utf8) else {
                    continue
                }
                // ファイルの URL は %XX を戻したパスで見る（ファイル名に入った値も拾うため）
                result.append(URL(string: string).flatMap { $0.isFileURL ? $0.path : nil } ?? string)
            }
        }
        if !hasPlainText {
            for item in snapshot.items {
                for type in [PasteboardTypes.rtf, PasteboardTypes.html] {
                    guard let data = item.data(for: type) else { continue }
                    result.append(String(decoding: data.prefix(SecretDetector.scanLimit), as: UTF8.self))
                }
            }
        }
        return result
    }

    static func plainText(of item: PasteboardItemSnapshot) -> String? {
        if let data = item.data(for: PasteboardTypes.utf8PlainText) ?? item.data(for: PasteboardTypes.plainText),
            let text = String(data: data, encoding: .utf8)
        {
            return text
        }
        for type in [PasteboardTypes.utf16ExternalPlainText, PasteboardTypes.utf16PlainText] {
            if let data = item.data(for: type), let text = String(data: data, encoding: .utf16) { return text }
        }
        return nil
    }
}
