import CryptoKit
import Foundation

/// 取り込まない理由（ログとテストに使う。中身は含めない）
public enum SkipReason: String, Sendable, Hashable {
    /// 型もデータもない変化（clearContents だけ等）
    case empty
    /// パスワード等の印（ConcealedType 等）が付いていた
    case excludedMarker
    /// サイズ上限を超えて、残せる型が 1 つもなかった
    case tooLarge
    /// 記録の一時停止中だった
    case paused
    /// 記録しないアプリ（設定の excludedApps）が前面にあった。データは読まない
    case excludedApp
    /// AI の口が保存してからクリップボードにも置いたもの（`PasteboardMarkers.savedByMakuripAI`）。データは読まない
    case savedByAI
}

public enum CaptureDecision: Sendable, Hashable {
    case accept(CapturedClip)
    case skip(SkipReason)
}

/// 取り込みの判定一式（純粋関数）。ペーストボードを読んだ結果を受け取り、保存するもの（`CapturedClip`）か、
/// 取り込まない理由を返す。ペーストボードそのものには触らない（読むのは `PasteboardReader`）。
public enum CapturePipeline {
    public struct Context: Sendable {
        public var now: Date
        public var frontmostApp: SourceApp?
        public var copyMethod: CopyMethod
        /// 読む段階で上限超えで落とした型の数（`PasteboardReader` が数える）
        public var droppedWhileReading: Int

        public init(now: Date, frontmostApp: SourceApp?, copyMethod: CopyMethod, droppedWhileReading: Int = 0) {
            self.now = now
            self.frontmostApp = frontmostApp
            self.copyMethod = copyMethod
            self.droppedWhileReading = droppedWhileReading
        }
    }

    public static func process(_ snapshot: PasteboardSnapshot, context: Context, limits: Limits) -> CaptureDecision {
        if PasteboardMarkers.containsExcludedMarker(snapshot.allTypes) { return .skip(.excludedMarker) }
        if snapshot.isEmpty { return .skip(context.droppedWhileReading > 0 ? .tooLarge : .empty) }

        let (trimmed, dropped) = SizePolicy.trim(snapshot, limits: limits)
        if trimmed.isEmpty { return .skip(.tooLarge) }

        var flags: Set<ClipFlag> = []
        if dropped + context.droppedWhileReading > 0 { flags.insert(.truncated) }

        let kind = KindClassifier.classify(trimmed)
        // 秘密っぽいもの（形式だけで判定）は印を付け、一覧用の平文を伏せ字にして入れる（画面・検索のどこからも中身が見えないように）
        let secret = SecretScanner.assess(trimmed)
        if let secret { flags.formUnion(secret.flags) }
        let clip = CapturedClip(
            snapshot: trimmed,
            contentHash: ContentHasher.hash(trimmed),
            kind: kind,
            copyMethod: context.copyMethod,
            source: context.frontmostApp,
            sourceURL: SourceURLExtractor.extract(from: trimmed),
            capturedAt: context.now,
            flags: flags,
            previewText: PreviewText.make(
                for: trimmed, kind: kind, limit: limits.previewCharacterLimit, maskSecrets: secret != nil)
        )
        return .accept(clip)
    }
}

/// サイズ上限の当てはめ（純粋関数）
public enum SizePolicy {
    /// 型 1 つの上限を超える型を落とし、1 件の合計が上限を超えるなら大きい型から落とす。
    /// 戻り値は（残ったもの, 落とした型の数）。型が 1 つも残らない項目は項目ごと消す
    public static func trim(_ snapshot: PasteboardSnapshot, limits: Limits) -> (PasteboardSnapshot, Int) {
        var dropped = 0
        var items = snapshot.items.map { item in
            let kept = item.representations.filter { $0.data.count <= limits.maxRepresentationBytes }
            dropped += item.representations.count - kept.count
            return PasteboardItemSnapshot(representations: kept)
        }

        var total = items.reduce(0) { $0 + $1.representations.reduce(0) { $0 + $1.data.count } }
        while total > limits.maxClipBytes {
            // いちばん大きい型を 1 つ落とす
            var largest: (item: Int, rep: Int, size: Int)?
            for (itemIndex, item) in items.enumerated() {
                for (repIndex, rep) in item.representations.enumerated() where rep.data.count > (largest?.size ?? -1) {
                    largest = (itemIndex, repIndex, rep.data.count)
                }
            }
            guard let target = largest else { break }
            items[target.item].representations.remove(at: target.rep)
            total -= target.size
            dropped += 1
        }

        let nonEmpty = items.filter { !$0.representations.isEmpty }
        return (PasteboardSnapshot(items: nonEmpty), dropped)
    }
}

/// 「同じ内容か」を決めるハッシュ（純粋関数）。
///
/// 全項目・全型の（型名, データ）を順に SHA-256 に通す。コピーのたびに変わる付随情報の型
/// （`PasteboardMarkers.volatileTypePrefixes`）は外す。同じ文字列でもコピー元のアプリが違い型の組が違えば別物になる。
public enum ContentHasher {
    public static func hash(_ snapshot: PasteboardSnapshot) -> String {
        var hasher = SHA256()
        for item in snapshot.items {
            hasher.update(data: Data("item\u{0}".utf8))
            for rep in item.representations where !PasteboardMarkers.isVolatile(rep.type) {
                hasher.update(data: Data(rep.type.utf8))
                hasher.update(data: Data("\u{0}\(rep.data.count)\u{0}".utf8))
                hasher.update(data: rep.data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// AI の口が足したものの「同じ内容か」のハッシュ。人のコピーのハッシュ（`hash`）とは別の空間にする。
    ///
    /// 同じ空間だと、AI の追加が人の項目に合流し、推した文字列が履歴にあるかが結果（先頭へ移したか・既存の id・件数）から分かる。
    /// 人の項目のコピー元・印・回数も AI のものに書き換わる（#24）。AI が足したもの同士は、今までどおり合流する
    public static func aiAdded(_ hash: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("makurip.addedByAI\u{0}".utf8))
        hasher.update(data: Data(hash.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 一覧・絞り込み用の短い平文（純粋関数）。
///
/// `maskSecrets` のときは、全文で秘密の値を伏せ字にしてから先頭を切る（切った境目で秘密の一部がのぞかないように）
public enum PreviewText {
    public static func make(for snapshot: PasteboardSnapshot, kind: ClipKind, limit: Int, maskSecrets: Bool = false)
        -> String?
    {
        switch kind {
        case .file:
            let names = KindClassifier.fileURLs(of: snapshot).map { $0.lastPathComponent }
            guard !names.isEmpty else { return nil }
            let joined = names.joined(separator: "\n")
            return String((maskSecrets ? SecretMask.masked(joined).text : joined).prefix(limit))
        case .image:
            return nil
        default:
            guard let text = KindClassifier.plainText(of: snapshot) else { return nil }
            let shown = maskSecrets ? SecretMask.masked(text).text : text
            let trimmed = shown.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(limit))
        }
    }
}
