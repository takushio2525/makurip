# Makurip のよく使うコマンド。詳細は AGENTS.md の「コマンド」節
.PHONY: build test lint format check app install e2e clean

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

clean:
	rm -rf .build .app-build
