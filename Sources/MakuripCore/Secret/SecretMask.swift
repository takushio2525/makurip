import Foundation

/// 秘密の値を伏せ字にする（純粋関数）。見せるのは、決まった形の接頭辞（`sk-ant-api03-`・`ghp_`・秘密鍵の BEGIN の行）と、
/// 十分に長い値の末尾 4 文字だけ。伏せ字の数は 8 か 16 にそろえ、元の長さも分からないようにする（`sk-test-••••••••••••••••0000`）
public enum SecretMask {
    public static let bullet: Character = "•"
    /// 末尾に見せる文字数（GitHub などの管理画面と同じ 4 文字）
    static let tailLength = 4
    /// 末尾を見せるのは、それを除いてもこれだけ隠れるときだけ
    static let minimumHiddenForTail = 16

    /// 伏せ字の数（隠す文字が 16 以上なら 16、それより少なければ 8）
    static func bulletCount(hidden: Int) -> Int { hidden >= 16 ? 16 : 8 }

    /// 秘密の値 1 つ（`value` は `finding` の範囲の文字列）の伏せ字
    public static func mask(_ value: String, finding: SecretFinding) -> String {
        let ns = value as NSString
        let prefixLength = min(finding.visiblePrefix, ns.length)
        let suffixLength = min(finding.visibleSuffix, ns.length - prefixLength)
        let prefix = ns.substring(to: prefixLength)
        let suffix = ns.substring(from: ns.length - suffixLength)
        let middle = ns.substring(
            with: NSRange(location: prefixLength, length: ns.length - prefixLength - suffixLength))
        var tail = ""
        var hidden = middle.count
        if finding.kind.revealsTail, middle.count - tailLength >= minimumHiddenForTail {
            tail = String(middle.suffix(tailLength))
            hidden -= tailLength
        }
        return prefix + String(repeating: bullet, count: bulletCount(hidden: hidden)) + tail + suffix
    }

    /// 見つけた秘密をすべて伏せ字にした文字列（`findings` は `text` の中の位置）
    public static func apply(_ findings: [SecretFinding], to text: String) -> String {
        guard !findings.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for finding in findings.sorted(by: { $0.location > $1.location })
        where finding.location + finding.length <= result.length {
            let value = result.substring(with: finding.range)
            result.replaceCharacters(in: finding.range, with: mask(value, finding: finding))
        }
        return result as String
    }

    /// 判定して伏せ字にする。秘密がなければ元のまま（`findings` は空）
    public static func masked(_ text: String) -> (text: String, findings: [SecretFinding]) {
        let findings = SecretDetector.findings(in: text)
        return (apply(findings, to: text), findings)
    }
}
