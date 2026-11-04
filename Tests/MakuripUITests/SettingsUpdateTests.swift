import Foundation
import MakuripCore
import Testing

@testable import MakuripUI

/// 設定画面の「アップデート」のまとまり（#43）。状態とボタンの行（画面だけ）と、自動の確認のオン・オフ（設定の項目）
@MainActor
@Suite("設定画面のアップデート")
struct SettingsUpdateTests {
    final class Fake {
        var status = UpdateStatus(currentVersion: "0.1.0")
        var checks = 0
        var installs = 0
        var skips = 0
    }

    let dir = SettingsTempDirectory()
    let fake = Fake()
    let controller: SettingsController
    let model: SettingsModel

    init() {
        let fake = fake
        controller = SettingsController(file: SettingsFile(directory: dir.url))
        model = SettingsModel(
            controller: controller,
            environment: SettingsEnvironment(
                update: UpdateEnvironment(
                    status: { fake.status }, check: { fake.checks += 1 }, install: { fake.installs += 1 },
                    skip: { fake.skips += 1 })))
        model.open()
    }

    static func release(_ version: String) throws -> UpdateRelease {
        let url = try #require(URL(string: "https://github.com/takushio2525/makurip/releases/download/v\(version)/x"))
        return UpdateRelease(
            version: try #require(AppVersion(version)), tag: "v\(version)", pageURL: nil, publishedAt: nil,
            archive: ReleaseAsset(name: "Makurip-\(version).zip", url: url, size: nil, sha256: nil),
            checksum: ReleaseAsset(name: "Makurip-\(version).zip.sha256", url: url, size: nil, sha256: nil))
    }

    func press(_ code: UInt16) {
        _ = model.handle(KeyStroke(keyCode: code, modifiers: []))
    }

    @Test("「アップデート」のまとまりは、状態の行の後に自動の確認のオン・オフ")
    func placement() throws {
        let section = try #require(model.sections.first { $0.title == "アップデート" })
        #expect(section.itemIDs == [SettingsModel.updateRowID, SettingID.autoUpdateCheck])
        #expect(model.updateStatus?.currentVersion == "0.1.0")
    }

    @Test("新しい版がなければ、状態の行の ↩ は手での確認")
    func returnChecks() {
        model.select(SettingsModel.updateRowID)
        press(KeyCodes.returnKey)
        #expect(fake.checks == 1)
        #expect(fake.installs == 0)
    }

    @Test("新しい版があれば、↩ で入れ替え、「この版は知らせない」も選べる")
    func installAndSkip() throws {
        fake.status = UpdateStatus(currentVersion: "0.1.0", availability: .available(try Self.release("0.2.0")))
        model.environmentDidChange()
        #expect(model.updateStatus?.offersInstall == true)
        model.select(SettingsModel.updateRowID)
        press(KeyCodes.returnKey)
        #expect(fake.installs == 1)
        #expect(model.message?.contains("起動し直します") == true)
        model.skipUpdate()
        #expect(fake.skips == 1)
        #expect(model.message == "v0.2.0 は知らせないようにしました。もっと新しい版が出たら知らせます。")
    }

    @Test("置き換えられない場所では入れ替えを出さず、↩ は確認になる")
    func blocked() throws {
        fake.status = UpdateStatus(
            currentVersion: "0.1.0", availability: .available(try Self.release("0.2.0")),
            blockedReason: UpdateFailure.translocated.message)
        model.environmentDidChange()
        model.select(SettingsModel.updateRowID)
        press(KeyCodes.returnKey)
        #expect(fake.installs == 0)
        #expect(fake.checks == 1)
    }

    @Test("自動の確認のオン・オフは ↩ で切り替わり、設定ファイルに書く（ほかのオン・オフの値に引きずられない）")
    func toggleAutoCheck() {
        #expect(controller.settings.autoUpdateCheck)
        model.select(SettingID.autoUpdateCheck)
        press(KeyCodes.returnKey)
        #expect(!controller.settings.autoUpdateCheck)
        #expect(!controller.settings.launchAtLogin)
        #expect(model.message == "「アップデートを自動で確認」を「しない」にしました。")
        press(KeyCodes.returnKey)
        #expect(controller.settings.autoUpdateCheck)
        // ログイン時に起動のオン・オフも、自分の値で切り替わる
        model.select(SettingID.launchAtLogin)
        press(KeyCodes.returnKey)
        #expect(controller.settings.launchAtLogin)
        #expect(controller.settings.autoUpdateCheck)
    }

    @Test("状態の 1 行: 最新・知らせない・失敗・確かめていない")
    func summaries() throws {
        let checked = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UpdateStatus(currentVersion: "0.1.0").summary == "まだ確かめていません。")
        #expect(UpdateStatus(currentVersion: "0.1.0", lastCheckedAt: checked).summary.hasPrefix("最新です（"))
        #expect(
            UpdateStatus(currentVersion: "0.1.0", availability: .skipped(try Self.release("0.2.0"))).summary
                == "新しい版 v0.2.0 は「この版は知らせない」にしています。")
        let failed = UpdateStatus(currentVersion: "0.1.0", phase: .failed(UpdateFailure.checksumMismatch.message))
        #expect(failed.summary.contains("sha256"))
        #expect(failed.summaryIsWarning)
        let offline = UpdateStatus(currentVersion: "0.1.0", lastCheckError: UpdateFailure.network("時間切れ").message)
        #expect(offline.summary.contains("時間切れ"))
        #expect(offline.summaryIsWarning)
    }

    @Test("アップデートの口がなければ、状態の行を出さない（オン・オフの項目は出る）")
    func absent() throws {
        let plain = SettingsModel(controller: controller)
        let section = try #require(plain.sections.first { $0.title == "アップデート" })
        #expect(section.itemIDs == [SettingID.autoUpdateCheck])
    }
}
