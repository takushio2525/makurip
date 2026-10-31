import AppKit
import MakuripCore

let options = LaunchOptions.parse(CommandLine.arguments)
let (dataDirectory, isolated) = DataDirectory.resolve(
    argument: options.dataDirectory, environment: ProcessInfo.processInfo.environment, bundleID: AppIdentity.bundleID)

/// 例のコマンドに使う実行ファイルの完全なパス（PATH の名前やリンクで呼ばれても、そのまま実行できる形にする）
func commandPrefix() -> String {
    let executable =
        Bundle.main.executablePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    func quoted(_ text: String) -> String {
        text.contains(where: { $0 == " " || $0 == "'" })
            ? "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'" : text
    }
    return quoted(executable) + (isolated ? " --data-dir \(quoted(dataDirectory.path))" : "")
}

/// 設定の CLI（`--settings`。MCP の設定の道具も同じものを通す）
func makeSettingsCLI() -> SettingsCLI {
    let file = SettingsFile(directory: dataDirectory)
    if !isolated {
        // 既定のデータフォルダでは、アプリより先に CLI を使っても UserDefaults の設定を引き継ぐ
        _ = try? SettingsMigration.migrateIfNeeded(file: file, defaults: .standard, domainName: AppIdentity.bundleID)
    }
    return SettingsCLI(
        file: file, command: commandPrefix() + " --settings",
        appName: { bundleID in NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map(\.path) })
}

/// AI の口の道具（MCP と `--ai` の CLI が同じものを使う）。UI もロックも使わない。
/// 書いたら分散通知で動いている Makurip に知らせる（一覧の読み直し・秘密の自動消去の掛け直し）
@MainActor
func makeAITools(channel: AIActivityEntry.Channel) -> AITools {
    let pasteboard: NSPasteboard =
        options.pasteboardName.map { NSPasteboard(name: NSPasteboard.Name($0)) } ?? .general
    let gateway = AIGateway(
        directory: dataDirectory, isolated: isolated,
        environment: AIGateway.Environment(
            pasteboard: { pasteboard },
            appRunning: { AppPresence.isRunning(directory: dataDirectory) },
            historyDidChange: { HistoryChangeSignal.post(directory: dataDirectory) }))
    return AITools(
        gateway: gateway, settingsCLI: makeSettingsCLI(), log: AIActivityLog(directory: dataDirectory),
        channel: channel,
        activityDidChange: { HistoryChangeSignal.postActivity(directory: dataDirectory) })
}

if let arguments = options.settingsArguments {
    // 設定の CLI（UI もロックも使わない。動いているインスタンスは設定ファイルの変化を見て読み直す）
    let output = makeSettingsCLI().run(arguments)
    FileHandle.standardOutput.write(Data(output.stdout.utf8))
    FileHandle.standardError.write(Data(output.stderr.utf8))
    exit(output.exitCode)
}

if options.mcp {
    // MCP のサーバー（標準入出力の JSON-RPC）。標準出力には応答だけを書く。標準入力が閉じたら終わる
    MCPServer(tools: makeAITools(channel: .mcp), version: AppIdentity.version).run()
    exit(0)
}

if let arguments = options.aiArguments {
    // AI の口の CLI（MCP と同じ道具）
    let cli = AICLI(
        tools: makeAITools(channel: .cli), command: commandPrefix() + " --ai",
        readStandardInput: {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        })
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
