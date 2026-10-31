import Foundation

/// コピー元ページの URL を、ペーストボードに載っていれば取り出す（純粋関数）。
///
/// 取れるもの:
/// - Chromium 系（Chrome・Edge・Arc・Brave 等）: `org.chromium.source-url`
/// - Safari 等の WebKit: `com.apple.webarchive` の `WebMainResource.WebResourceURL`
///
/// 取れないもの: Firefox（ページ URL を載せない）、ネイティブアプリ、ブラウザの JavaScript が
/// `navigator.clipboard.writeText` で書いたもの（コピーボタン。平文しか載らない）。
public enum SourceURLExtractor {
    public static func extract(from snapshot: PasteboardSnapshot) -> String? {
        if let data = snapshot.firstData(for: PasteboardTypes.chromiumSourceURL),
            let url = webURL(from: data)
        {
            return url
        }
        if let data = snapshot.firstData(for: PasteboardTypes.webArchive),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let main = plist["WebMainResource"] as? [String: Any],
            let string = main["WebResourceURL"] as? String,
            isWebURL(string)
        {
            return string
        }
        return nil
    }

    static func webURL(from data: Data) -> String? {
        let candidates = [String(data: data, encoding: .utf8), String(data: data, encoding: .utf16)]
        for case let string? in candidates {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            if isWebURL(trimmed) { return trimmed }
        }
        return nil
    }

    static func isWebURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
    }
}
