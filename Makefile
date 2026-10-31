# Makurip のよく使うコマンド。詳細は AGENTS.md の「コマンド」節
.PHONY: build test lint format check app install e2e e2e-settings e2e-secrets ui-compare clean

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

# 試作（案 B）と SwiftUI のパネルを同じ状態で描いて並べる（画面ロック中でも動く。出力は .ui-compare/）
ui-compare:
	design/ui-compare/shoot.sh

clean:
	rm -rf .build .app-build
