import Foundation

/// 貼り付けのときにペーストボードへ書き戻す中身を決める（純粋関数）。保存してある履歴は変えない。
///
/// - `.plainText`: 文字の型だけ（平文の型がなければ全型）。コマンドのプロンプトは外さない（元のまま貼る逃げ道。試作どおり）
/// - `.normal`・`.copyOnly`: 全型。コマンドなら、文字の型（UTF-8・UTF-16）の中身だけプロンプトを外す。
///   RTF・HTML などほかの型と、項目・型の並びは元のまま（書き手の書式を壊さないため）
public enum PastePipeline {
    public static func prepare(_ stored: PasteboardSnapshot, kind: ClipKind?, mode: PasteMode) -> PasteboardSnapshot {
        switch mode {
        case .plainText:
            return stored.plainTextOnly() ?? stored
        case .normal, .copyOnly:
            guard kind == .command else { return stored }
            return strippingPrompts(stored)
        }
    }

    /// 文字の型の中身からプロンプトを外した写し。外すものがなければ元のまま
    public static func strippingPrompts(_ snapshot: PasteboardSnapshot) -> PasteboardSnapshot {
        var result = snapshot
        for itemIndex in result.items.indices {
            for repIndex in result.items[itemIndex].representations.indices {
                let rep = result.items[itemIndex].representations[repIndex]
                guard let encoding = TextEncoding(type: rep.type, data: rep.data),
                    let text = encoding.decode(rep.data)
                else { continue }
                let analysis = ShellPrompt.analyze(text)
                guard analysis.hasPrompt, let data = encoding.encode(analysis.stripped) else { continue }
                result.items[itemIndex].representations[repIndex].data = data
            }
        }
        return result
    }

    /// 文字の型の符号化。UTF-16 は元のデータの BOM と並びに合わせて書き戻す
    enum TextEncoding {
        case utf8
        case utf16(bom: Bool, bigEndian: Bool)

        init?(type: String, data: Data) {
            switch type {
            case PasteboardTypes.utf8PlainText, PasteboardTypes.plainText:
                self = .utf8
            case PasteboardTypes.utf16PlainText, PasteboardTypes.utf16ExternalPlainText:
                let bytes = [UInt8](data.prefix(2))
                if bytes == [0xFE, 0xFF] {
                    self = .utf16(bom: true, bigEndian: true)
                } else if bytes == [0xFF, 0xFE] {
                    self = .utf16(bom: true, bigEndian: false)
                } else {
                    self = .utf16(bom: false, bigEndian: false)
                }
            default:
                return nil
            }
        }

        func decode(_ data: Data) -> String? {
            switch self {
            case .utf8:
                return String(data: data, encoding: .utf8)
            case .utf16(let bom, let bigEndian):
                let body = bom ? data.dropFirst(2) : data
                return String(data: Data(body), encoding: bigEndian ? .utf16BigEndian : .utf16LittleEndian)
            }
        }

        func encode(_ text: String) -> Data? {
            switch self {
            case .utf8:
                return text.data(using: .utf8)
            case .utf16(let bom, let bigEndian):
                guard let body = text.data(using: bigEndian ? .utf16BigEndian : .utf16LittleEndian) else { return nil }
                guard bom else { return body }
                return Data(bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE]) + body
            }
        }
    }
}
