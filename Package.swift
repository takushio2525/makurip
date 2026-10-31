// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Info.plist は Sources/Makurip/Info.plist の 1 か所だけに置く（表示名・バンドル ID・版の正本）。
// .app の Contents/Info.plist にはこれをそのまま写し（scripts/build-app.sh）、
// 素の実行ファイルにも __TEXT,__info_plist として埋め込む（--dump-metadata を素のまま実行しても
// Bundle.main からバンドル ID が読めるように）。
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let infoPlistPath = "\(packageRoot)/Sources/Makurip/Info.plist"

let package = Package(
    name: "Makurip",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Makurip", targets: ["Makurip"]),
        .executable(name: "MakuripDevTool", targets: ["MakuripDevTool"]),
    ],
    targets: [
        // UI に依存しない本体（モデル・判定・取り込み・書き戻し・ストア）
        .target(
            name: "MakuripCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // 仮の一覧。フェーズ2で丸ごと差し替える
        .target(
            name: "MakuripUI",
            dependencies: ["MakuripCore"]
        ),
        // アプリ本体（メニューバー・ホットキー・監視・貼り付け）
        .executableTarget(
            name: "Makurip",
            dependencies: ["MakuripCore", "MakuripUI"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlistPath,
                ]),
            ]
        ),
        // 検証用 CLI（.app には入れない）
        .executableTarget(
            name: "MakuripDevTool",
            dependencies: ["MakuripCore"]
        ),
        .testTarget(
            name: "MakuripCoreTests",
            dependencies: ["MakuripCore"]
        ),
    ]
)
