import AppKit
import MakuripCore

let options = LaunchOptions.parse(CommandLine.arguments)
let (dataDirectory, isolated) = DataDirectory.resolve(
    argument: options.dataDirectory, environment: ProcessInfo.processInfo.environment, bundleID: AppIdentity.bundleID)

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
