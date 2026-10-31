import Foundation
import Testing

@testable import MakuripCore

/// コマンドのプロンプトを外す処理。壊さないこと（迷う行を外さないこと）を中心に確かめる
@Suite("コマンドのプロンプトを外す")
struct ShellPromptTests {
    @Test(
        "1 行",
        arguments: [
            ("$ git switch -c feature/history-panel", "git switch -c feature/history-panel"),
            ("% npm run build && npm run preview", "npm run build && npm run preview"),
            ("❯ swift test", "swift test"),
            ("➜ make", "make"),
        ])
    func singleLine(_ input: String, _ expected: String) {
        #expect(ShellPrompt.strip(input) == expected)
    }

    @Test("複数行（行ごとに外す。空行は残す）")
    func multipleLines() {
        #expect(
            ShellPrompt.strip("$ brew install swiftlint\n$ swiftlint --fix && swiftlint")
                == "brew install swiftlint\nswiftlint --fix && swiftlint")
        #expect(ShellPrompt.strip("$ cd app\n\n$ make") == "cd app\n\nmake")
        // 改行が \r\n でも外す（\r\n は 1 文字として扱われるので \n で分けられないことに注意）
        #expect(ShellPrompt.strip("$ ls\r\n$ pwd\r\n") == "ls\r\npwd\r\n")
    }

    @Test("出力の行は残す（出力の中の $ や % も外さない）")
    func outputLines() {
        let input = """
            $ ls
            README.md  Sources
            $ du -sh .
            12M\t.
            % done
            """
        let analysis = ShellPrompt.analyze(input)
        #expect(analysis.stripped == "ls\nREADME.md  Sources\ndu -sh .\n12M\t.\ndone")
        #expect(analysis.promptRanges.count == 3)
        // 出力の行の途中の $ はそのまま
        #expect(ShellPrompt.strip("$ echo $HOME\n/Users/sample $ ok") == "echo $HOME\n/Users/sample $ ok")
    }

    @Test(
        "PS1（user@host・[user@host dir]・zsh・bash-3.2・venv・oh-my-zsh）",
        arguments: [
            ("user@host:~$ ls -la", "ls -la"),
            ("user@host:~/work/app$ make", "make"),
            ("root@server:/etc# systemctl restart nginx", "systemctl restart nginx"),
            ("[user@host app]$ make build", "make build"),
            ("sample@MacBook-Pro ~ % brew update", "brew update"),
            ("(venv) sample@MacBook-Pro app % pip install -r requirements.txt", "pip install -r requirements.txt"),
            ("bash-3.2$ echo hi", "echo hi"),
            ("➜  makurip git:(main) ✗ make check", "make check"),
            ("➜  makurip make check", "make check"),
        ])
    func ps1(_ input: String, _ expected: String) {
        #expect(ShellPrompt.strip(input) == expected)
    }

    @Test("行の頭の $VAR・$(…)・jQuery の $ は外さない")
    func dollarInCode() {
        for input in [
            "$HOME/bin/tool --help", "$(brew --prefix)/bin/tool", "$('#id').hide()", "$1 is the first argument",
        ] {
            #expect(ShellPrompt.strip(input) == input)
            #expect(!ShellPrompt.analyze(input).hasPrompt)
        }
        // プロンプトの後ろの $VAR は残る
        #expect(ShellPrompt.strip("$ echo $PATH") == "echo $PATH")
    }

    @Test("# のコメントと root の「# 」を見分ける")
    func rootPromptVersusComment() {
        // 全部の行が「# コマンド」なら root のプロンプト
        #expect(ShellPrompt.strip("# apt update\n# apt install -y nginx") == "apt update\napt install -y nginx")
        #expect(ShellPrompt.strip("# systemctl restart nginx") == "systemctl restart nginx")
        // コメントの行が 1 つでもあれば、全部コメント
        let mixed = "# 依存を入れる\nnpm install"
        #expect(ShellPrompt.strip(mixed) == mixed)
        let english = "# install the dependencies\nnpm install"
        #expect(ShellPrompt.strip(english) == english)
        // ほかのプロンプトがあるときの # はコメント
        #expect(ShellPrompt.strip("$ make\n# make clean もある") == "make\n# make clean もある")
        #expect(ShellPrompt.strip("$ ls\n# rm -rf build") == "ls\n# rm -rf build")
        // # の後ろに空白がない・見出し・shebang は外さない
        for input in ["#!/bin/zsh", "#comment", "# Makurip の使い方", "# Install"] {
            #expect(ShellPrompt.strip(input) == input)
        }
    }

    @Test("続き行の「> 」は前の行が閉じていないときだけ外す")
    func continuation() {
        #expect(ShellPrompt.strip("$ docker run \\\n> -p 80:80 \\\n> nginx") == "docker run \\\n-p 80:80 \\\nnginx")
        #expect(ShellPrompt.strip("$ echo \"a\n> b\"") == "echo \"a\nb\"")
        #expect(ShellPrompt.strip("$ ls |\n> wc -l") == "ls |\nwc -l")
        // ヒアドキュメント（bash は「> 」、zsh は「heredoc> 」）
        #expect(ShellPrompt.strip("$ cat <<EOF\n> line 1\n> EOF") == "cat <<EOF\nline 1\nEOF")
        #expect(ShellPrompt.strip("% cat <<EOF\nheredoc> x\nheredoc> EOF") == "cat <<EOF\nx\nEOF")
        // 閉じた後の「> 」は出力（npm の「> pkg@1.0.0 build」など）として残す
        let npm = "$ npm run build\n> makurip@1.0.0 build\n> vite build"
        #expect(ShellPrompt.strip(npm) == "npm run build\n> makurip@1.0.0 build\n> vite build")
        // 引用符の中の \ や # は数えない
        #expect(ShellPrompt.strip("$ echo 'a\\'\n> b") == "echo 'a\\'\n> b")
    }

    @Test("プロンプトのない文字列はそのまま（空・空行だけ・ふつうのコマンド）")
    func noPrompt() {
        for input in ["", "\n\n", "git status", "npm install && npm test", "echo 100% done", "  $ indented"] {
            #expect(ShellPrompt.strip(input) == input)
            #expect(!ShellPrompt.analyze(input).hasPrompt)
        }
    }

    @Test("範囲は UTF-16 で、全角の混じった行でも正しい位置を指す")
    func utf16Ranges() {
        let input = "$ echo 「こんにちは」\n$ ls 📁"
        let analysis = ShellPrompt.analyze(input)
        #expect(analysis.promptRanges == [NSRange(location: 0, length: 2), NSRange(location: 15, length: 2)])
        #expect(analysis.stripped == "echo 「こんにちは」\nls 📁")
    }

    @Test("迷う形（➜ の後ろに空白 2 つでディレクトリだけ）は外さない")
    func ambiguous() {
        #expect(ShellPrompt.strip("➜  ~") == "➜  ~")
    }
}
