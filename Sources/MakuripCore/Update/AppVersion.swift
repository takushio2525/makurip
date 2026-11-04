import Foundation

/// 版（X.Y.Z）。Release の tag（`vX.Y.Z`）と Info.plist の `CFBundleShortVersionString`（`X.Y.Z`）を同じ形で読む。
///
/// 数 3 つだけを認める（`1.2`・`1.2.3-beta`・`01.2.3` は版として読まない）。prerelease は Release の印で除くので、
/// 版の文字列に後ろ書きを付けて区別することはしない（`.agent/conventions.md` の「アップデート」）
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible, Codable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// `X.Y.Z` か `vX.Y.Z`。形が違えば nil
    public init?(_ text: String) {
        var body = Substring(text.trimmingCharacters(in: .whitespaces))
        if body.first == "v" { body = body.dropFirst() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            // 数字だけ・6 桁まで・先頭に余分な 0 を付けない
            guard !part.isEmpty, part.count <= 6, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                part.count == 1 || part.first != "0", let number = Int(part)
            else { return nil }
            numbers.append(number)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    /// Release の tag の形（`vX.Y.Z`）
    public var tag: String { "v\(description)" }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = AppVersion(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "版の形ではない"))
        }
        self = version
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
