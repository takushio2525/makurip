import Foundation

/// アップデートが止まった理由。どれも置き換える前に止まる（`replaceFailed` だけは置き換えの途中で、元の版へ戻してから返す）。
///
/// 文（`message`）は利用者がメニュー・設定画面・CLI で読んで、何が起きたか分かるように書く。
/// チーム ID・証明書の名前・designated requirement の中身は文に入れない（公開のリポジトリ・ログに出さないため）
public enum UpdateFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// GitHub（差し替えた配信元）に問い合わせられない・ダウンロードできない
    case network(String)
    /// Release の一覧を読めない（JSON の形が違う）
    case feedUnreadable
    /// 本番で、GitHub の Release のダウンロードの場所でない URL を指していた
    case downloadNotAllowed
    /// 決まった大きさを超えた
    case tooLarge
    /// Release に書かれた大きさと、落としたものの大きさが違う
    case sizeMismatch
    /// sha256 のファイルの形が違う（1 行・64 桁の 16 進・zip の名前）
    case checksumFileInvalid
    /// 落とした zip の sha256 が、sha256 のファイル（か Release の digest）と違う
    case checksumMismatch
    /// zip を展開できない
    case extractFailed(String)
    /// zip の中に .app が 1 つだけ入っていない
    case bundleMissing
    /// 署名が壊れている・中身が書き換えられている・署名がない
    case signatureInvalid
    /// バンドル ID が今の版と違う
    case bundleIDMismatch
    /// チーム ID がない・今の版と違う
    case teamMismatch
    /// designated requirement が今の版と違う（入れ替えるとアクセシビリティの許可が外れる）
    case requirementMismatch
    /// Apple の公証を通っていない
    case notNotarized
    /// .app の版が Release の版と違う
    case versionMismatch(expected: String, found: String?)
    /// 今の版より新しくない
    case notNewer
    /// .app の中から動いていない（`swift run` など）ので置き換えられない
    case notInstalledAsApp
    /// macOS が隔離した場所（App Translocation）で動いている
    case translocated
    /// 置き場所に書けない
    case notWritable
    /// 今の Makurip に使える署名がない（比べる相手がない）
    case currentUnsigned
    /// ディスクの Makurip が、動いている版と違う（ほかで入れ替えた）
    case alreadyReplaced
    /// 置き換えに失敗した（元の版のまま）
    case replaceFailed(String)
    /// ほかのアップデートが進んでいる
    case busy

    /// 機械向けの ID（CLI の JSON・状態の書き出し）
    public var code: String {
        switch self {
        case .network: "network"
        case .feedUnreadable: "feedUnreadable"
        case .downloadNotAllowed: "downloadNotAllowed"
        case .tooLarge: "tooLarge"
        case .sizeMismatch: "sizeMismatch"
        case .checksumFileInvalid: "checksumFileInvalid"
        case .checksumMismatch: "checksumMismatch"
        case .extractFailed: "extractFailed"
        case .bundleMissing: "bundleMissing"
        case .signatureInvalid: "signatureInvalid"
        case .bundleIDMismatch: "bundleIDMismatch"
        case .teamMismatch: "teamMismatch"
        case .requirementMismatch: "requirementMismatch"
        case .notNotarized: "notNotarized"
        case .versionMismatch: "versionMismatch"
        case .notNewer: "notNewer"
        case .notInstalledAsApp: "notInstalledAsApp"
        case .translocated: "translocated"
        case .notWritable: "notWritable"
        case .currentUnsigned: "currentUnsigned"
        case .alreadyReplaced: "alreadyReplaced"
        case .replaceFailed: "replaceFailed"
        case .busy: "busy"
        }
    }

    public var message: String {
        switch self {
        case .network(let detail): "Release を確かめられませんでした（\(detail)）。"
        case .feedUnreadable: "Release の一覧を読めませんでした（形が違います）。"
        case .downloadNotAllowed: "ダウンロードの場所が GitHub の Release ではないので、落としませんでした。"
        case .tooLarge: "ダウンロードが大きすぎるので止めました。"
        case .sizeMismatch: "ダウンロードした zip の大きさが Release の記載と違うので、入れ替えませんでした。"
        case .checksumFileInvalid: "sha256 のファイルの形が違うので、入れ替えませんでした。"
        case .checksumMismatch: "ダウンロードした zip の sha256 が一致しないので、入れ替えませんでした。"
        case .extractFailed(let detail): "zip を展開できませんでした（\(detail)）。"
        case .bundleMissing: "zip の中に Makurip の .app が 1 つだけ入っていないので、入れ替えませんでした。"
        case .signatureInvalid: "署名が壊れているか、中身が書き換えられているので、入れ替えませんでした。"
        case .bundleIDMismatch: "バンドル ID が今の Makurip と違うので、入れ替えませんでした。"
        case .teamMismatch: "署名したチームが今の Makurip と違うので、入れ替えませんでした。"
        case .requirementMismatch:
            "署名の要件（designated requirement）が今の Makurip と違うので、入れ替えませんでした（入れ替えるとアクセシビリティの許可が外れるため）。"
        case .notNotarized: "Apple の公証を通っていないので、入れ替えませんでした。"
        case .versionMismatch(let expected, let found):
            "中の .app の版（\(found ?? "不明")）が Release の版（\(expected)）と違うので、入れ替えませんでした。"
        case .notNewer: "今の版より新しくないので、入れ替えませんでした。"
        case .notInstalledAsApp: "Makurip.app の中から動いていないので、置き換えられません。"
        case .translocated:
            "macOS が隔離した場所で動いているので、置き換えられません。Makurip.app を「アプリケーション」フォルダへ移してから開き直してください。"
        case .notWritable: "Makurip.app の置き場所に書けないので、置き換えられません。"
        case .currentUnsigned: "今の Makurip に使える署名がないので、新しい版と比べられません。"
        case .alreadyReplaced: "ディスクの Makurip.app が、動いている版と違います（ほかで入れ替えた）。Makurip を起動し直してください。"
        case .replaceFailed(let detail): "置き換えに失敗しました（\(detail)）。今の版のままです。"
        case .busy: "ほかのアップデートが進んでいます。"
        }
    }

    public var description: String { message }

    /// CLI の終了コード（2: 確かめで断った・3: 通信やファイルの失敗）
    public var exitCode: Int32 {
        switch self {
        case .network, .extractFailed, .notWritable, .replaceFailed, .busy, .tooLarge: 3
        default: 2
        }
    }
}
