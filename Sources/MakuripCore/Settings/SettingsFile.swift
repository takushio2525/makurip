import Foundation

/// 設定ファイル（`<データフォルダ>/settings.json`）。アプリと CLI が同じコードで読み書きする。
///
/// ```json
/// {
///   "formatVersion" : 1,
///   "settings" : {
///     "hotkeyMode" : "paste",
///     "keys.open" : [ "⌥V" ]
///   }
/// }
/// ```
///
/// - 既定と違う値だけを書く（既定を変えたら、変えていない人には新しい既定が効く。試作の保存と同じ）
/// - 知らない項目（新しい版が書いたもの）は読み飛ばして、書き戻すときにそのまま残す
/// - 値が検証に通らない項目は既定に戻し、`issues` に理由を残す。JSON として読めないファイルは既定で動き、
///   次に保存するときに `settings.broken.json` へ退避してから書き直す
/// - データフォルダごとに 1 つなので、`--data-dir` で隔離したインスタンスの設定は本物と混ざらない
public struct SettingsFile: Sendable {
    public static let fileName = "settings.json"
    public static let brokenFileName = "settings.broken.json"
    public static let formatVersion = 1

    public let directory: URL
    public var url: URL { directory.appendingPathComponent(Self.fileName) }

    public init(directory: URL) {
        self.directory = directory
    }

    /// 読んだ結果
    public struct Contents: Sendable, Equatable {
        public var settings: AppSettings
        /// 知らない項目（書き戻すときに残す）
        public var unknown: [String: JSONValue]
        /// 読めなかった・使わなかった項目の理由（画面と `list` に出す）
        public var issues: [SettingsError]
        public var exists: Bool
        /// JSON として読めなかった
        public var broken: Bool

        public static let empty = Contents(settings: .default, unknown: [:], issues: [], exists: false, broken: false)
    }

    public func load() -> Contents {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        return Self.decode(data)
    }

    /// 読み込みの本体（純粋関数）
    public static func decode(_ data: Data) -> Contents {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data), let object = root.objectValue,
            let values = (object["settings"] ?? .object([:])).objectValue
        else {
            return Contents(
                settings: .default, unknown: [:],
                issues: [SettingsError(id: fileName, message: "JSON として読めないので、すべて既定の値で動いている")],
                exists: true, broken: true)
        }
        var contents = Contents(settings: .default, unknown: [:], issues: [], exists: true, broken: false)
        if let version = object["formatVersion"]?.intValue, version > formatVersion {
            contents.issues.append(
                SettingsError(id: fileName, message: "新しい版（\(version)）の設定ファイル。知っている項目だけを使う"))
        }
        // キーの重なりは後の項目ほど前の項目に勝たないよう、ここでは見ない（画面と list に出す）
        for id in values.keys.sorted() {
            guard let raw = values[id] else { continue }
            guard SettingsSchema.item(id) != nil else {
                contents.unknown[id] = raw
                contents.issues.append(SettingsError(id: id, message: "知らない項目なので使わない（ファイルには残す）"))
                continue
            }
            switch SettingsSchema.applying(raw, to: id, in: contents.settings, keyConflicts: .allow) {
            case .success(let change): contents.settings = change.settings
            case .failure(let error):
                contents.issues.append(SettingsError(id: id, message: error.message + "。既定の値を使っている"))
            }
        }
        return contents
    }

    /// 書く本体（純粋関数）。既定と違う値と、知らない項目だけ
    public static func encode(_ settings: AppSettings, unknown: [String: JSONValue] = [:]) -> Data {
        var values = unknown
        for item in SettingsSchema.items {
            guard let value = SettingsSchema.value(item.id, in: settings) else { continue }
            if value != SettingsSchema.defaultValue(item.id) { values[item.id] = value }
        }
        let root: JSONValue = .object(["formatVersion": .int(formatVersion), "settings": .object(values)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(root)) ?? Data()) + Data("\n".utf8)
    }

    /// 書く（同じフォルダの一時ファイルに書いてから置き換える。読む側が書きかけを見ない）
    public func save(_ settings: AppSettings, unknown: [String: JSONValue] = [:], backingUpBroken: Bool = false) throws
    {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if backingUpBroken, FileManager.default.fileExists(atPath: url.path) {
            let backup = directory.appendingPathComponent(Self.brokenFileName)
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        try Self.encode(settings, unknown: unknown).write(to: url, options: .atomic)
    }
}

/// UserDefaults の時代（#8）の候補窓の設定を設定ファイルへ引き継ぐ。
///
/// - 読むのは**永続ドメインだけ**（`defaults write` で書いた値。起動引数の `-hotkeyMode` などは引き継がない）
/// - 設定ファイルがまだないときに 1 回だけ。写した値は UserDefaults から消す（設定ファイルを消して初期化したときに戻ってこないように）
/// - 既定のデータフォルダのときだけ呼ぶ（隔離したインスタンスに本物の設定を持ち込まない）
public enum SettingsMigration {
    public static let legacyKeys = [
        CandidateSettings.Key.hotKeyMode, CandidateSettings.Key.order, CandidateSettings.Key.pasteTiming,
        CandidateSettings.Key.replaceMethod, CandidateSettings.Key.idleTimeout,
    ]

    /// 永続ドメインの値を設定に写す（純粋関数）。写せた項目と、写せなかった理由を返す
    public static func importLegacy(_ domain: [String: Any], into settings: inout AppSettings) -> (
        imported: [String], rejected: [SettingsError]
    ) {
        var imported: [String] = []
        var rejected: [SettingsError] = []
        for key in legacyKeys {
            guard var value = domain[key].flatMap(jsonValue) else { continue }
            // アプリごとの辞書は、壊れた組だけを捨てて残りを写す（UserDefaults の時代の読み方と同じ）
            if let object = value.objectValue, let item = SettingsSchema.item(key) {
                value = .object(
                    object.filter { entry in
                        (try? SettingsSchema.validate(.object([entry.key: entry.value]), for: item).get()) != nil
                    })
            }
            switch SettingsSchema.applying(value, to: key, in: settings, keyConflicts: .allow) {
            case .success(let change):
                settings = change.settings
                imported.append(key)
            case .failure(let error):
                rejected.append(error)
            }
        }
        return (imported, rejected)
    }

    static func jsonValue(_ raw: Any) -> JSONValue? {
        switch raw {
        case let value as String: return .string(value)
        case let value as NSNumber: return .number(value.doubleValue)
        case let value as [String: Any]:
            return .object(value.compactMapValues { ($0 as? String).map(JSONValue.string) })
        default: return nil
        }
    }

    /// 設定ファイルがなければ、UserDefaults の永続ドメイン `domainName` から引き継いで書く。引き継いだ項目の ID を返す
    @discardableResult
    public static func migrateIfNeeded(file: SettingsFile, defaults: UserDefaults, domainName: String) throws
        -> [String]
    {
        guard !FileManager.default.fileExists(atPath: file.url.path),
            let domain = defaults.persistentDomain(forName: domainName)
        else { return [] }
        var settings = AppSettings.default
        let (imported, _) = importLegacy(domain, into: &settings)
        guard !imported.isEmpty || legacyKeys.contains(where: { domain[$0] != nil }) else { return [] }
        try file.save(settings)
        for key in legacyKeys { defaults.removeObject(forKey: key) }
        return imported
    }
}
