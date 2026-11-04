import CryptoKit
import Foundation

/// sha256 のファイル（`Makurip-X.Y.Z.zip.sha256`）の読み取りと、ファイルの sha256。
///
/// ファイルの形は `shasum -a 256 Makurip-X.Y.Z.zip` の出力そのまま（`<64 桁の 16 進>  Makurip-X.Y.Z.zip` の 1 行）。
/// 名前の前の `*`（二進の印）は認める。名前が違う・行が 2 つ以上・16 進が 64 桁でないものは受け付けない
/// （別の版の sha256 を取り違えて照らさないため）
public enum UpdateChecksum {
    /// sha256 のファイルの上限（1 行なので小さい）
    public static let maxFileBytes = 4096

    public static func parse(_ text: String, expectedFileName: String) throws -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count == 1, let line = lines.first else { throw UpdateFailure.checksumFileInvalid }
        let fields = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count == 2, let hex = normalizedHex(String(fields[0])) else {
            throw UpdateFailure.checksumFileInvalid
        }
        var name = fields[1].trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("*") { name.removeFirst() }
        guard name == expectedFileName else { throw UpdateFailure.checksumFileInvalid }
        return hex
    }

    /// 64 桁の 16 進なら小文字にして返す
    static func normalizedHex(_ text: String) -> String? {
        let lower = text.lowercased()
        guard lower.count == 64, lower.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return lower
    }

    /// ファイルの sha256（16 進の小文字）。大きいファイルも 1 MB ずつ読む
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
