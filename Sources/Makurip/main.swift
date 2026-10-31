import AppKit
import MakuripCore

let options = LaunchOptions.parse(CommandLine.arguments)
let (dataDirectory, isolated) = DataDirectory.resolve(
    argument: options.dataDirectory, environment: ProcessInfo.processInfo.environment, bundleID: AppIdentity.bundleID)

if let arguments = options.settingsArguments {
    // 設定の CLI（UI もロックも使わない。動いているインスタンスは設定ファイルの変化を見て読み直す）
    let file = SettingsFile(directory: dataDirectory)
    if !isolated {
        // 既定のデータフォルダでは、アプリより先に CLI を使っても UserDefaults の設定を引き継ぐ
        _ = try? SettingsMigration.migrateIfNeeded(file: file, defaults: .standard, domainName: AppIdentity.bundleID)
    }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    func quoted(_ text: String) -> String {
        text.contains(where: { $0 == " " || $0 == "'" })
            ? "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'" : text
    }
    let command = quoted(executable) + (isolated ? " --data-dir \(quoted(dataDirectory.path))" : "") + " --settings"
    let cli = SettingsCLI(
        file: file, command: command,
        appName: { bundleID in NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map(\.path) })
    let output = cli.run(arguments)
    FileHandle.standardOutput.write(Data(output.stdout.utf8))
    FileHandle.standardError.write(Data(output.stderr.utf8))
    exit(output.exitCode)
}

if options.dumpMetadata {
    // メタデータだけを書き出して終わる（UI もロックも使わない。動いているインスタンスがあっても読める）
    let databaseExists = FileManager.default.fileExists(
        atPath: dataDirectory.appendingPathComponent(ClipStore.databaseFileName).path)
    do {
        let dump =
            databaseExists
            ? try MetadataDump.make(from: ClipStore(directory: dataDirectory))
            : MetadataDump.empty
        print(try dump.jsonString())
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("メタデータを読めなかった: \(error)\n".utf8))
        exit(1)
    }
}

let application = NSApplication.shared
let controller = AppController(options: options, dataDirectory: dataDirectory, isolated: isolated)
application.delegate = controller
// Dock に出さない（Info.plist の LSUIElement と同じ。素の実行ファイルで起動したときのため）
application.setActivationPolicy(.accessory)
application.run()
