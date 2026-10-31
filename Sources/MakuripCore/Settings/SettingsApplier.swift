import Foundation

/// 設定を反映する相手（本番は `AppController`。テストでは偽物）
@MainActor
public protocol SettingsApplying: AnyObject {
    /// 件数・容量の上限（下げたら、超えた古い履歴をその場で消す）
    func applyLimits(_ limits: Limits)
    /// 記録しないアプリ（小文字のバンドル ID）
    func applyExcludedApps(_ bundleIDs: Set<String>)
    /// どこからでも効くキー（Carbon のホットキーを付け替える。nil は登録しない）
    func applyGlobalKeys(open: HotKey?, openList: HotKey?)
    /// 一覧・候補窓のキーと画面のヒント
    func applyKeymap(_ keymap: Keymap)
    /// 呼び出しキーの動き・候補窓の並び・アプリごとの貼り方
    func applyCandidateSettings(_ settings: CandidateSettings)
    /// ログイン時に起動（起動したときには呼ばない。変えたときだけ）
    func applyLaunchAtLogin(_ enabled: Bool)
    /// 秘密を自動で消すまでの秒数（短くしたら、時間を過ぎたものをその場で消す）
    func applySecretRetention(_ retention: TimeInterval)
}

/// 設定の変化を、変わった部分だけ反映先へ渡す
public enum SettingsApplier {
    /// `previous` が nil（起動したとき）は、ログイン時の起動以外をすべて渡す
    @MainActor
    public static func apply(_ new: AppSettings, previous: AppSettings?, to target: SettingsApplying) {
        if previous?.limits != new.limits { target.applyLimits(new.limits) }
        if previous?.excludedAppSet != new.excludedAppSet { target.applyExcludedApps(new.excludedAppSet) }
        let open = new.globalHotKey(.openHistory)
        let openList = new.globalHotKey(.openList)
        if previous == nil || previous?.globalHotKey(.openHistory) != open
            || previous?.globalHotKey(.openList) != openList
        {
            target.applyGlobalKeys(open: open, openList: openList)
        }
        if previous?.keymap != new.keymap { target.applyKeymap(new.keymap) }
        if previous?.candidate != new.candidate { target.applyCandidateSettings(new.candidate) }
        if let previous, previous.launchAtLogin != new.launchAtLogin { target.applyLaunchAtLogin(new.launchAtLogin) }
        if previous?.secretRetention != new.secretRetention { target.applySecretRetention(new.secretRetention) }
    }
}
