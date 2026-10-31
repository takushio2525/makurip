# Makurip のよく使うコマンド。詳細は AGENTS.md の「コマンド」節
.PHONY: build test lint format check app install e2e ui-compare clean

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

# 試作（案 B）と SwiftUI のパネルを同じ状態で描いて並べる（画面ロック中でも動く。出力は .ui-compare/）
ui-compare:
	design/ui-compare/shoot.sh

clean:
	rm -rf .build .app-build
