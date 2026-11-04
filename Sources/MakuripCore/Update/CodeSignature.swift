import Foundation
import Security

/// .app の署名から読んだもの（比べるための値。画面・ログ・CLI には出さない）
public struct CodeIdentity: Equatable, Sendable {
    public var bundleID: String?
    public var version: String?
    public var teamID: String?
    /// designated requirement の文字列（アクセシビリティの許可はこれに紐づく）
    public var designatedRequirement: String?
    /// 署名が厳しい確かめ（全アーキテクチャ・入れ子・封をした資源）に通るか
    public var signatureValid: Bool
    /// Apple の公証を通っているか（staple した票か、Apple への問い合わせで）
    public var notarized: Bool

    public init(
        bundleID: String?, version: String?, teamID: String?, designatedRequirement: String?, signatureValid: Bool,
        notarized: Bool
    ) {
        self.bundleID = bundleID
        self.version = version
        self.teamID = teamID
        self.designatedRequirement = designatedRequirement
        self.signatureValid = signatureValid
        self.notarized = notarized
    }
}

/// 署名の読み取り（Security.framework）。外部ライブラリ・codesign コマンドは使わない
public enum CodeSignature {
    static let strictFlags = SecCSFlags(
        rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)

    /// .app の署名を読む。署名がない・壊れているときは `signatureValid` が false
    public static func identity(ofBundle url: URL) -> CodeIdentity {
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        var identity = CodeIdentity(
            bundleID: info?["CFBundleIdentifier"] as? String, version: info?["CFBundleShortVersionString"] as? String,
            teamID: nil, designatedRequirement: nil, signatureValid: false, notarized: false)
        guard let code = staticCode(url) else { return identity }
        identity.signatureValid = SecStaticCodeCheckValidity(code, strictFlags, nil) == errSecSuccess
        var signing: CFDictionary?
        if SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing)
            == errSecSuccess, let signing = signing as? [String: Any]
        {
            identity.teamID = signing[kSecCodeInfoTeamIdentifier as String] as? String
        }
        identity.designatedRequirement = designatedRequirement(of: code)
        if identity.signatureValid, let notarized = requirement("notarized") {
            identity.notarized = SecStaticCodeCheckValidity(code, strictFlags, notarized) == errSecSuccess
        }
        return identity
    }

    /// `candidate` の .app が、`requirement`（今の版の designated requirement）を満たすか。
    /// 満たせば、入れ替えてもアクセシビリティの許可が引き継がれる
    public static func satisfies(_ candidate: URL, requirement text: String) -> Bool {
        guard let code = staticCode(candidate), let requirement = requirement(text) else { return false }
        return SecStaticCodeCheckValidity(code, strictFlags, requirement) == errSecSuccess
    }

    private static func staticCode(_ url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }

    private static func designatedRequirement(of code: SecStaticCode) -> String? {
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else {
            return nil
        }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }

    private static func requirement(_ text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }
}

/// 新しい版の .app を入れ替えてよいかの判断（純粋関数）。順に、署名 → バンドル ID → チーム ID →
/// designated requirement（文字列が同じで、今の版の要件を満たす）→ 公証 → 版、を見る。最初に外れたところで理由を返す
public enum UpdateVerification {
    public static func check(
        candidate: CodeIdentity, satisfiesCurrentRequirement: Bool, current: CodeIdentity, expected: AppVersion,
        running: AppVersion, policy: UpdatePolicy
    ) -> UpdateFailure? {
        guard current.signatureValid, current.teamID != nil, current.designatedRequirement != nil else {
            return .currentUnsigned
        }
        guard candidate.signatureValid else { return .signatureInvalid }
        guard let bundleID = candidate.bundleID, bundleID == current.bundleID else { return .bundleIDMismatch }
        guard let team = candidate.teamID, team == current.teamID else { return .teamMismatch }
        guard candidate.designatedRequirement == current.designatedRequirement, satisfiesCurrentRequirement else {
            return .requirementMismatch
        }
        if policy.requireNotarization, !candidate.notarized { return .notNotarized }
        guard let found = candidate.version.flatMap(AppVersion.init), found == expected else {
            return .versionMismatch(expected: expected.description, found: candidate.version)
        }
        guard found > running else { return .notNewer }
        return nil
    }
}
