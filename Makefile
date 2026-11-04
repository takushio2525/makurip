# Makurip のよく使うコマンド。詳細は AGENTS.md の「コマンド」節
.PHONY: build test lint format check app install e2e e2e-settings e2e-secrets e2e-snippets e2e-ai e2e-click ui-compare clean

build:
	swift build

test:
	swift test

lint:
	swift format lint --strict --recursive Package.swift Sources Tests

format:
	swift format --in-place --recursive Package.swift Sources Tests

# 完了報告の前に通すもの
check: lint build test

app:
	scripts/build-app.sh

install:
	scripts/install.sh

# 隔離した取り込み・永続化の E2E（一般ペーストボードに触らない）
e2e:
	scripts/e2e/capture.sh

# 設定の隔離 E2E（CLI で変えて、動いているインスタンスにすぐ効くか。窓は出さず、ホットキーは使われていない組み合わせだけ）
e2e-settings:
	scripts/e2e/settings.sh

# 秘密の隔離 E2E（偽物のキーで印・伏せ字・自動消去・当て直し。1 分で消す設定にするので 2〜3 分かかる）
e2e-secrets:
	scripts/e2e/secrets.sh

# 定型文の隔離 E2E（snippets.json を書いて登録し、置き換えた文字を名前付きペーストボードへ書き戻す。窓を出さず、キーも送らない）
e2e-snippets:
	scripts/e2e/snippets.sh

# AI の口の隔離 E2E（目印入りの履歴に MCP の全道具を JSON-RPC で呼び、応答に目印が 0 件か。動いているアプリへの反映・オフ・巨大な要求も）
e2e-ai:
	scripts/e2e/ai.sh

# 一覧のカードのクリックと右クリックのメニューの隔離 E2E（#38。一覧を仮想ディスプレイ tako-vd に出し、窓の中で作った出来事で押す。
# 一般ペーストボードに触らず、本物のマウス・キーも使わない。tako-vd が無い・画面ロック中なら何もせずに終わる）
e2e-click:
	scripts/e2e/click.sh

# 試作（案 B）と SwiftUI のパネルを同じ状態で描いて並べる（画面ロック中でも動く。出力は .ui-compare/）
ui-compare:
	design/ui-compare/shoot.sh

clean:
	rm -rf .build .app-build
