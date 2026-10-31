import Foundation

/// コードの言語を見分ける（純粋関数）。経験則なので確実ではない。手がかりが足りなければ nil（色付けは最小限にする）。
///
/// 順番:
/// 1. Markdown のコードブロックの言語名（```swift）
/// 2. 1 行目の shebang（`#!/bin/zsh`・`#!/usr/bin/env python3`）
/// 3. 形で決まるもの: JSON（JSONSerialization で読める）・XML（`<?xml`）・HTML（タグで始まりタグで閉じる）・YAML（`key:` の並び）
/// 4. 言語ごとの手がかり（正規表現と重み）の点数がいちばん高いもの。`minimumScore` に届かなければ nil
///
/// 長い文字列は先頭 `inspectLimit` 文字だけを見る。見分けられない例は `.agent/conventions.md` の「判定の限界」。
public enum CodeLanguageDetector {
    static let inspectLimit = 3000
    /// これより低い点数なら言語を決めない
    static let minimumScore = 4

    public static func detect(_ text: String) -> CodeLanguage? {
        let head = text.prefix(inspectLimit)
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let fenced = fenceLanguage(trimmed) { return fenced }
        if let shebang = shebangLanguage(trimmed) { return shebang }
        // JSON は全体を読めるかで決める（長すぎるものは先頭の形で）
        let isLong = text.utf16.count > jsonParseLimit
        let json = isLong ? trimmed : text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isJSON(json, isPrefix: isLong) { return .json }
        if let markup = markupLanguage(trimmed) { return markup }
        if isYAML(trimmed) { return .yaml }
        return scoredLanguage(sample(text))
    }

    /// JSON として全体を読む上限（UTF-16）。これより長いものは先頭の形で決める
    static let jsonParseLimit = 200_000
    /// 点数を付けるときの 1 行の上限（とても長い 1 行で見る範囲を使い切らないように）
    static let lineLimit = 300
    static let maxLines = 200

    /// 点数を付ける範囲: 先頭から最大 `maxLines` 行、各行は `lineLimit` 文字まで、合計 `inspectLimit` 文字まで
    static func sample(_ text: String) -> String {
        var result = ""
        for line in text.split(maxSplits: maxLines, omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            result += line.prefix(lineLimit)
            result += "\n"
            if result.count >= inspectLimit { break }
        }
        return result
    }

    /// 点数（テスト・調整用）
    static func scores(_ sample: String) -> [CodeLanguage: Int] {
        let range = NSRange(location: 0, length: (sample as NSString).length)
        var result: [CodeLanguage: Int] = [:]
        for (language, signals) in signalTable {
            var score = 0
            for signal in signals {
                let count = min(signal.pattern.numberOfMatches(in: sample, range: range), signal.cap)
                score += count * signal.weight
            }
            if score > 0 { result[language] = score }
        }
        return result
    }

    // MARK: 形で決まるもの

    static func fenceLanguage(_ trimmed: String) -> CodeLanguage? {
        guard trimmed.hasPrefix("```") else { return nil }
        let firstLine = trimmed.prefix { $0 != "\n" }.dropFirst(3)
        let tag = firstLine.split(separator: " ").first.map(String.init) ?? ""
        return CodeLanguage(fenceTag: tag)
    }

    static func shebangLanguage(_ trimmed: String) -> CodeLanguage? {
        guard trimmed.hasPrefix("#!") else { return nil }
        let line = trimmed.prefix { $0 != "\n" }.lowercased()
        if line.contains("python") { return .python }
        if line.contains("node") || line.contains("deno") || line.contains("bun") { return .javascript }
        if line.contains("ruby") { return .ruby }
        if line.range(of: #"\b(ba|z|k|da|fi)?sh\b"#, options: .regularExpression) != nil { return .shell }
        return nil
    }

    /// JSON のオブジェクトか配列。長くて途中で切った文字列は、`{"key":` の形で見る
    static func isJSON(_ trimmed: String, isPrefix: Bool) -> Bool {
        guard let first = trimmed.first, first == "{" || first == "[" else { return false }
        if !isPrefix, let last = trimmed.last, last == "}" || last == "]",
            let data = trimmed.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
        {
            return true
        }
        guard isPrefix else { return false }
        return trimmed.range(of: #"^[\[\s]*\{\s*"[^"\n]+"\s*:"#, options: .regularExpression) != nil
    }

    static func markupLanguage(_ trimmed: String) -> CodeLanguage? {
        let lower = trimmed.prefix(200).lowercased()
        if lower.hasPrefix("<?xml") || lower.hasPrefix("<!doctype plist") || lower.hasPrefix("<plist") {
            return .xml
        }
        if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") { return .html }
        guard trimmed.hasPrefix("<"), trimmed.hasSuffix(">") else { return nil }
        // タグで始まりタグで終わり、閉じタグか自分で閉じるタグがあるもの
        let hasClosing = trimmed.range(of: #"</[A-Za-z][\w:-]*\s*>|/>"#, options: .regularExpression) != nil
        guard hasClosing else { return nil }
        let htmlTag =
            #"<(div|span|p|a|ul|ol|li|img|button|input|form|table|tr|td|section|header|footer|nav|main|body|head|script|style|link|meta|template|h[1-6]|br|label|select|option|textarea|svg|path|article|aside|figure)\b"#
        return trimmed.range(of: htmlTag, options: [.regularExpression, .caseInsensitive]) != nil ? .html : .xml
    }

    static let yamlKeyLine = try! NSRegularExpression(pattern: #"^\s*(?:- +)?["']?[A-Za-z_][\w.\-/ ]*["']?:(?:\s|$)"#)
    static let yamlListLine = try! NSRegularExpression(pattern: #"^\s*- +\S"#)

    /// YAML: 空でない行（コメントを除く）がすべて `key:`・`- 値`・続きの字下げ行で、
    /// 入れ子の `key:`（値が空）か `- ` の並び、`---` のどれかがあるもの（「注意: …」のような文章を外すため）
    static func isYAML(_ trimmed: String) -> Bool {
        let lines = trimmed.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        guard lines.count >= 2 else { return false }
        var keyLines = 0
        var structural = trimmed.hasPrefix("---")
        for (index, line) in lines.enumerated() {
            let range = NSRange(location: 0, length: (line as NSString).length)
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine == "---" || trimmedLine == "..." { continue }
            if trimmedLine.hasSuffix(";") || trimmedLine.hasSuffix("{") || trimmedLine.hasSuffix("}")
                || trimmedLine.hasSuffix("(") || trimmedLine.hasPrefix("//")
            {
                return false
            }
            if yamlKeyLine.firstMatch(in: line, range: range) != nil {
                keyLines += 1
                if trimmedLine.hasSuffix(":") || trimmedLine.hasPrefix("- ") { structural = true }
                continue
            }
            if yamlListLine.firstMatch(in: line, range: range) != nil {
                structural = true
                continue
            }
            // 字下げした続きの行（ブロックの文字列）は、前に key: があればよい
            if index > 0, line.first == " " || line.first == "\t", keyLines > 0 { continue }
            return false
        }
        return keyLines >= 2 && structural
    }

    // MARK: 手がかりの点数

    struct Signal {
        let pattern: NSRegularExpression
        let weight: Int
        /// 同じ手がかりを数える上限（1 つの書き方が何度も出て点数を独り占めしないように）
        let cap: Int
    }

    static func signal(_ pattern: String, _ weight: Int, cap: Int = 3, caseInsensitive: Bool = false) -> Signal {
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if caseInsensitive { options.insert(.caseInsensitive) }
        return Signal(pattern: try! NSRegularExpression(pattern: pattern, options: options), weight: weight, cap: cap)
    }

    /// 最も点数の高い言語。同点なら表の順（先にある方）
    static func scoredLanguage(_ sample: String) -> CodeLanguage? {
        let scores = scores(sample)
        var best: CodeLanguage?
        var bestScore = minimumScore - 1
        for (language, _) in signalTable {
            guard let score = scores[language], score > bestScore else { continue }
            best = language
            bestScore = score
        }
        guard let language = best else { return nil }
        // JavaScript と TypeScript、C と C++ は共通の手がかりが多いので、固有の手がかりの点で分ける
        func ownScore(_ language: CodeLanguage, minus base: CodeLanguage) -> Int {
            (scores[language] ?? 0) - (scores[base] ?? 0)
        }
        switch language {
        case .javascript, .typescript:
            return ownScore(.typescript, minus: .javascript) >= 4 ? .typescript : .javascript
        case .c, .cpp:
            return ownScore(.cpp, minus: .c) >= 4 ? .cpp : .c
        default:
            return language
        }
    }

    /// 言語ごとの手がかり。JavaScript の点は TypeScript にも足す（TypeScript は固有の手がかりがあるときだけ選ぶ）
    static let signalTable: [(CodeLanguage, [Signal])] = {
        let javascript: [Signal] = [
            signal(#"\b(const|let) [A-Za-z_$][\w$]* = "#, 2),
            signal(#"\bconst [a-z_$][\w$]*\b"#, 1),
            signal(#"=>"#, 2),
            signal(#"\bfunction\b"#, 3),
            signal(#"\bconsole\.\w+\("#, 4),
            signal(#"\brequire\(['"]"#, 4),
            signal(#"\bmodule\.exports\b"#, 4),
            signal(#"^\s*import .+ from ['"]"#, 4),
            signal(#"^\s*import ['"]"#, 3),
            signal(#"^\s*export (default |const |function |class |async |\{)"#, 3),
            signal(#"===|!=="#, 3),
            signal(#"\b(document|window)\.\w+"#, 2),
            signal(#"\.then\(|new Promise\b|\basync \(|\bawait fetch\("#, 2),
            signal(#"\b(undefined|null)\b"#, 1),
            signal(#"`[^`\n]*\$\{"#, 2),
        ]
        let typescriptOnly: [Signal] = [
            signal(#"[\w)\]?]\s*:\s*(string|number|boolean|any|unknown|void|never|object)\b(\[\])?"#, 4),
            signal(#"^\s*(export )?interface \w+(<[^>]*>)? (extends [\w, ]+ )?\{"#, 3),
            signal(#"^\s*(export )?type \w+(<[^>]*>)? = "#, 3),
            signal(#"\bas const\b|\bimport type\b|\bkeyof\b|\breadonly \w"#, 3),
            signal(#"\b(public|private|protected) (readonly )?\w+(\?)?: "#, 2),
            signal(#"\): (Promise<|[A-Z]\w*(<.*>)?(\[\])? \{|string|number|boolean|void)"#, 3),
        ]
        let swift: [Signal] = [
            signal(
                #"^\s*import (SwiftUI|Foundation|UIKit|AppKit|Combine|XCTest|Testing|Cocoa|Observation|Dispatch|CoreGraphics)\s*$"#,
                5),
            signal(#"\bfunc \w+(<[^>]*>)?\("#, 3),
            signal(#"\b(guard|if|while) (let|var) \w+"#, 4),
            signal(#"\bguard .+ else \{"#, 4),
            signal(
                #"@(State|Binding|Published|MainActor|ObservedObject|StateObject|Environment|Observable|objc|escaping|discardableResult|available|Test|Suite|ViewBuilder|frozen|inlinable)\b"#,
                4),
            signal(#"\bsome (View|Scene|Sendable|Collection|Sequence)\b"#, 4),
            signal(
                #"^\s*(public |private |fileprivate |internal |final )*(struct|class|enum|extension|protocol|actor) \w+(<[^>]*>)?: \w+"#,
                3),
            signal(#"\) (async )?(throws )?-> [A-Z\[\(]\w*"#, 3),
            signal(#"\(\.\w+[,)]|: \.\w+[,)]"#, 2),
            signal(#"\\\(\w"#, 3),
            signal(#"\bcase \.\w+"#, 3),
            signal(#"\b(let|var) \w+: [A-Z]\w*[?!]?( =|$)"#, 2),
            signal(#"\bnil\b"#, 1),
            signal(#"\btry\??!? (await )?\w+"#, 2),
            signal(#"\bdefer \{"#, 2),
            signal(#"\bself\.\w+"#, 1),
        ]
        let python: [Signal] = [
            signal(#"^\s*(async )?def \w+\(.*\)\s*(->\s*[^:]+)?:\s*$"#, 5),
            signal(#"^\s*from [\w.]+ import \w"#, 5),
            signal(#"^\s*import [\w.]+( as \w+)?(, [\w.]+)*\s*$"#, 1),
            signal(#"^\s*class \w+(\(.*\))?:\s*$"#, 4),
            signal(#"^\s*(if|elif|while|for|with|try|except|else|finally)\b.*:\s*(#.*)?$"#, 2),
            signal(#"\belif\b"#, 3),
            signal(#"\b(None|True|False)\b"#, 2),
            signal(#"\bself\b"#, 1),
            signal(#"\blambda \w*:"#, 3),
            signal(#"__\w+__"#, 3),
            signal(#"\bexcept\b|\braise \w"#, 3),
            signal(#"^\s*@\w+(\.\w+)*(\(.*\))?\s*$"#, 1),
            signal(#"\b(print|len|range|isinstance|enumerate)\("#, 1),
            signal(#"^\s*"""|^\s*'''"#, 2),
            signal(#"\bf"[^"\n]*\{"#, 2),
        ]
        let go: [Signal] = [
            signal(#"^package \w+\s*$"#, 5),
            signal(#"^import \($"#, 4),
            signal(#"^import "[\w./-]+"\s*$"#, 4),
            signal(#"\bfunc \(\w+ \*?\w+\) \w+\("#, 6),
            signal(#"\bfunc \w+\((\w+ [\w*\[\].]+(, )?)*\)"#, 2),
            signal(#":= "#, 3),
            signal(#"\bfmt\.\w+\("#, 5),
            signal(#"\berr != nil\b"#, 5),
            signal(#"^type \w+ (struct|interface) \{"#, 5),
            signal(#"\bgo func\b|\bchan \w|<-\s*\w"#, 3),
            signal(#"\bnil\b"#, 1),
        ]
        let rust: [Signal] = [
            signal(#"\bfn \w+(<[^>]*>)?\("#, 4),
            signal(#"\blet mut \w+"#, 5),
            signal(#"^\s*impl(<[^>]*>)? \w+"#, 4),
            signal(#"\bpub (fn|struct|enum|mod|use|crate|trait)\b"#, 4),
            signal(#"^\s*use (std|crate|super|self)::"#, 5),
            signal(#"\b\w+!\(|\bvec!\["#, 4),
            signal(#"^\s*#!?\[\w+"#, 4),
            signal(#"&(mut )?self\b|&str\b|\bSome\(|\bOk\(|\bErr\("#, 3),
            signal(#"\bmatch \w+ \{"#, 2),
            signal(#"\w+::\w+"#, 1),
        ]
        let c: [Signal] = [
            signal(#"^\s*#include <\w+\.h>"#, 5),
            signal(#"^\s*#include ""#, 3),
            signal(#"^\s*#(define|ifdef|ifndef|endif|pragma) "#, 3),
            signal(#"\bint main\("#, 4),
            signal(#"\b(printf|fprintf|malloc|calloc|free|sizeof|memcpy|strlen)\("#, 3),
            signal(#"\bNULL\b"#, 2),
            signal(#"\b(unsigned|uint\d+_t|size_t|char ?\*)"#, 2),
            signal(#"^\s*(static |const )*(void|int|char|float|double|long) \**\w+\(.*\)\s*\{?\s*$"#, 3),
            signal(#"\w->\w"#, 1),
        ]
        let cppOnly: [Signal] = [
            signal(
                #"^\s*#include <(iostream|vector|string|map|unordered_map|memory|algorithm|cstdio|cstdlib|array|thread)>"#,
                5),
            signal(#"\bstd::"#, 5),
            signal(#"\bcout\s*<<|\bcin\s*>>|\bendl\b"#, 5),
            signal(#"\btemplate\s*<"#, 4),
            signal(#"\busing namespace\b|^\s*namespace \w+"#, 5),
            signal(#"^\s*(public|private|protected):\s*$"#, 3),
            signal(#"\bnullptr\b|\bauto \w+ = |\bconst \w+&"#, 3),
            signal(#"\b\w+::\w+\("#, 2),
        ]
        let java: [Signal] = [
            signal(#"\bpublic (static )?(final )?(abstract )?(class|interface|enum|record|void)\b"#, 4),
            signal(#"\bpublic static void main\(String"#, 6),
            signal(#"\bSystem\.(out|err)\.print"#, 6),
            signal(#"^import (java|javax|org|com)\.[\w.*]+;"#, 5),
            signal(#"^package [\w.]+;"#, 5),
            signal(#"@Override\b"#, 5),
            signal(#"\bprivate (static )?final\b|\bnew \w+<.*>\(\)"#, 3),
            signal(#"\b(String|Integer|ArrayList|HashMap)\b"#, 1),
        ]
        let kotlin: [Signal] = [
            signal(#"\bfun (<[^>]*> )?\w+\("#, 5),
            signal(#"\bval \w+(: [\w<>?]+)? = "#, 4),
            signal(#"\bdata class\b|\bcompanion object\b|^\s*object \w+"#, 5),
            signal(#"\bwhen \(.*\) \{|\bwhen \{"#, 3),
            signal(#"\?\.(let|also|apply|run)\b|\bit\.\w+|\bby lazy\b"#, 4),
            signal(#"^import (kotlinx?|android|androidx)\."#, 5),
            signal(#"^package \w+(\.\w+)+\s*$"#, 2),
            signal(#"\bprintln\("#, 1),
        ]
        let ruby: [Signal] = [
            signal(#"^\s*def \w+[?!]?(\(.*\))?\s*$"#, 3),
            signal(#"^\s*end\s*$"#, 4),
            signal(#"\bputs\b"#, 4),
            signal(#"^\s*require(_relative)? ['"]"#, 4),
            signal(#"\bdo \|\w+(, \w+)*\|"#, 5),
            signal(#"\{ \|\w+(, \w+)*\|"#, 4),
            signal(#"\battr_(accessor|reader|writer)\b"#, 5),
            signal(#"\b(unless|elsif)\b"#, 4),
            signal(#"^\s*class \w+( < [\w:]+)?\s*$"#, 3),
            signal(#"^\s*module \w+\s*$"#, 3),
            signal(#"@\w+ = "#, 1),
        ]
        let commandHeads = TextHeuristics.knownCommands.filter { $0.allSatisfy { $0.isLetter || $0 == "-" } }
            .sorted().joined(separator: "|")
        let shell: [Signal] = [
            signal(#"^\s*(sudo )?("# + commandHeads + #")( |$)"#, 2, cap: 4),
            signal(#"\$\{?[A-Za-z_]\w*\}?|\$[0-9@#?]"#, 2),
            signal(#"^\s*(if \[|elif \[|then\s*$|fi\s*$|do\s*$|done\s*$|esac\s*$)"#, 4),
            signal(#"\|\s*(grep|awk|sed|xargs|sort|head|tail|wc|tee|jq|cut|tr)\b"#, 4),
            signal(#"(^| )--?[a-zA-Z][\w-]*"#, 1),
            signal(#"^\s*export [A-Z_][A-Z0-9_]*="#, 4),
            signal(#"2>&1|>\s*/dev/null|&>"#, 5),
            signal(#"^\s*[A-Za-z_][A-Za-z0-9_]*=[^\s=]"#, 1),
            signal(#"\$\("#, 3),
        ]
        let css: [Signal] = [
            signal(#"^\s*[.#]?[\w-]+([\s,>+~]+[.#:]?[\w-]+)*(:{1,2}[\w-]+)?\s*\{\s*$"#, 1),
            signal(#"^\s*[a-z-]+\s*:\s*[^;{}]+;\s*$"#, 3, cap: 4),
            signal(#"^\s*@(media|import|keyframes|font-face|tailwind|supports|layer)\b"#, 5),
            signal(#"\b\d+(\.\d+)?(px|em|rem|vh|vw|vmin|vmax|pt|ms|s|deg|fr)\b"#, 2),
            signal(#":(hover|focus|active|root|before|after|first-child|last-child|nth-child)\b"#, 4),
            signal(#"!important\b"#, 4),
            signal(#"\bvar\(--[\w-]+\)"#, 4),
        ]
        // SQL のキーワードは大文字か小文字にそろっている。「Select the …」のような英文の頭（先頭だけ大文字）は数えない
        let sql: [Signal] = [
            signal(
                #"^\s*(SELECT|INSERT INTO|UPDATE \w+ SET|DELETE FROM|CREATE (TABLE|INDEX|VIEW|UNIQUE INDEX|TRIGGER)|ALTER TABLE|DROP (TABLE|INDEX|VIEW)|WITH \w+ AS)\b"#,
                6),
            signal(
                #"^\s*(select|insert into|update \w+ set|delete from|create (table|index|view|unique index|trigger)|alter table|drop (table|index|view)|with \w+ as)\b"#,
                3),
            signal(#"\b(FROM|WHERE|JOIN|GROUP BY|ORDER BY|HAVING|LIMIT|VALUES|PRIMARY KEY|NOT NULL)\b"#, 2),
            signal(#"\b(from|where|join|group by|order by|having|limit|values)\b"#, 1),
        ]
        return [
            (.swift, swift),
            (.typescript, javascript + typescriptOnly),
            (.javascript, javascript),
            (.python, python),
            (.go, go),
            (.rust, rust),
            (.kotlin, kotlin),
            (.java, java),
            (.cpp, c + cppOnly),
            (.c, c),
            (.ruby, ruby),
            (.sql, sql),
            (.css, css),
            (.shell, shell),
        ]
    }()
}
