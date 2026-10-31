# Makurip（マクリップ）

Mac 用のクリップボード履歴アプリ。コピーしたものを種類を問わず保存しておき、⌃⌘V で呼び出して、元いたアプリにそのまま貼り付けられる。

名前は「MaClip」を日本語で読んだ音「マクリップ」に、「履歴を**まくる**」をかけている。

> 状況: フェーズ1（土台）。一覧の見た目は仮で、フェーズ2で作り直す（`.agent/roadmap.md`）。

## できること（フェーズ1）

- テキスト・リッチテキスト・画像・PDF・ファイル・色・アプリ独自の形式まで、コピーされたものを**全項目・全型そのまま**保存する（貼り直すと元どおり）
- 再起動しても履歴が残る。保存先はこの Mac の中だけ（`~/Library/Application Support/com.takushio2525.makurip/`）
- ⌃⌘V で一覧を開き、文字を打って絞り込み、↑↓ で選んで Enter で元のアプリへ貼り付く。Esc で閉じる
- 種類（テキスト / リッチテキスト / 画像 / ファイル / URL / 色 / コード / コマンド / その他）・コピー方法（キー操作か、それ以外か）・コピー元のアプリを記録する（絞り込みの画面はフェーズ2）
- パスワード管理アプリが「保存しないで」と印を付けたもの（`org.nspasteboard.ConcealedType` 等）は保存しない
- 同じ内容は増やさず先頭へ移す。上限: 1000 件・合計 1 GB（ピン留めは数えない）。型 1 つ 50 MB を超えるものは落とす
- メニューバーから: 一覧を開く・記録を一時停止・履歴を消去・終了。Dock には出ない

判定の仕方と、見分けられないもの（限界）は `.agent/conventions.md` の「判定の限界」にまとめてある。

## ビルドと導入

必要なもの: Xcode 26.2 以降（コマンドラインツール込み）・キーチェーンにある Apple Development の証明書。

```bash
# 1. 署名の設定（初回だけ）。証明書の一覧は security find-identity -v -p codesigning
cp Config/signing.local.env.example Config/signing.local.env
#    → MAKURIP_SIGN_IDENTITY に証明書の 40 桁のハッシュを入れる（このファイルは git 管理外）

# 2. 確認（lint・ビルド・単体テスト）
make check

# 3. 組み立てて署名し、~/Applications/Makurip.app へ入れる
make install

# 4. 起動
open ~/Applications/Makurip.app
```

### アクセシビリティの許可（初回だけ）

貼り付け（元のアプリへ ⌘V を送る）と、コピー方法の記録（⌘C を見る）に必要。
システム設定 > プライバシーとセキュリティ > アクセシビリティ で **Makurip** をオンにする（メニューの「アクセシビリティを許可…」からも開ける）。

許可はコード署名と置き場所に紐づくので、Apple Development の証明書で署名し、いつも `~/Applications/Makurip.app` に入れる。
`make install` で入れ直しても許可は残る。アドホック署名だとビルドし直すたびに許可が消える。

許可がないあいだも履歴の記録はできる（コピー方法は「不明」になる）。貼り付けは、選んだものをペーストボードへ戻すところまでで止まる（自分で ⌘V を押せば貼れる）。

## 開発

| 用途 | コマンド |
|---|---|
| ビルド | `make build` |
| 単体テスト | `make test` |
| lint / 整形 | `make lint` / `make format` |
| 取り込み・永続化の E2E（一般ペーストボードに触らない） | `make e2e` |
| 一覧・貼り付けの E2E（画面ロック解除と許可が要る） | `scripts/e2e/paste.sh` |
| メタデータだけを書き出す | `~/Applications/Makurip.app/Contents/MacOS/Makurip --dump-metadata` |

検証では `--data-dir` で隔離したデータフォルダを使う（起動引数は `.agent/api.md`）。AI 向けの規約は `AGENTS.md`。
