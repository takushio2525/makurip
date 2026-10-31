// 秘密の判定（#5）の E2E に使う偽の秘密の本体。どれも実行のたびに作る乱数で、実在しない値。
// ソースに本物の形式どおりの値を書かないため、接頭辞は呼ぶ側で文字列をつないで作る。

/// 頭に置く決まった並び（大文字 → 小文字 → 数字の巡りどおり）。Base64 として読むと 0x67 0x1F 0x10 0x9B… になり、
/// 画像・ファイルの頭にも、文章を符号化したものにも見えない
let fakeSecretHead = Array("Zx8Qm4")

/// 偽の秘密の本体。ランダムな文字列の判定の条件を必ず満たす（`SecretDetector.looksRandom` は 8 文字以上、
/// 確度「中」の `randomToken` は 20〜512 文字。`Tests/MakuripDevToolTests/FakeSecretTests.swift` が守る）。
///
/// 英数字の一様な乱数では、同じ大きさの英字の 5 文字以上の連続が 35% を超えたり、`your`・`here`・`xxxx` のような
/// プレースホルダの語が入ったりして、40 文字で約 0.7%（`sk-test-` の後ろの 32 文字で約 1.2%）が判定から外れ、
/// E2E がまれに落ちた（#21）。そこで文字の種類を 1 文字ごとに大文字 → 小文字 → 数字と巡らせ、種類の中では
/// 混ぜた並びから重ならないように引く（尽きたら混ぜ直す）。頭の 6 文字は `fakeSecretHead` で、残りには出さない。これで
/// - 同じ種類が隣り合わない（種類の切り替わりは 100%・同じ大きさの英字の連続はない）。頭があるので数字は 2 つ以上、大文字と小文字が入り混じる
/// - 英字が 3 つ以上続かないので、プレースホルダの語（英字 4 文字以上）にも、既知の形式の接頭辞（`AKIA`・`AIza` など）にもならない
/// - 同じ文字は、その種類を一巡するまで（大文字・小文字は 24 字、数字は 8 字）出ない（エントロピーが足りる）。頭が 16 進・UUID・ULID にならない
/// - 80 文字までは、Base64 として読んでも印字できない 3 バイトが 5% 以上を占める（文章を符号化したものに見えない）
func fakeSecretBody(_ count: Int, using generator: inout some RandomNumberGenerator) -> String {
    let rest = { (characters: String) in Array(characters).filter { !fakeSecretHead.contains($0) } }
    var pools = [
        FakeSecretPool(rest("ABCDEFGHIJKLMNOPQRSTUVWXYZ")), FakeSecretPool(rest("abcdefghijklmnopqrstuvwxyz")),
        FakeSecretPool(rest("0123456789")),
    ]
    var result = String(fakeSecretHead.prefix(max(0, count)))
    for index in result.count..<max(result.count, count) {
        result.append(pools[index % 3].next(using: &generator))
    }
    return result
}

func fakeSecretBody(_ count: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    return fakeSecretBody(count, using: &generator)
}

/// 偽の秘密鍵の本体の 1 行（Base64 の文字の一様な乱数。秘密鍵は BEGIN と END の行で見つけるので、並びは問わない）
func fakeBase64Line(_ count: Int) -> String {
    let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
    return String((0..<count).map { _ in characters.randomElement()! })
}

/// 1 種類の文字を、混ぜた並びから重ならないように順に出す（尽きたら混ぜ直す）
struct FakeSecretPool {
    let characters: [Character]
    var queue: [Character] = []

    init(_ characters: [Character]) { self.characters = characters }

    mutating func next(using generator: inout some RandomNumberGenerator) -> Character {
        if queue.isEmpty { queue = characters.shuffled(using: &generator) }
        return queue.removeLast()
    }
}
