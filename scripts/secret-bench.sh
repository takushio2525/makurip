#!/bin/bash
# tako:run scripts/secret-bench.sh
#
# 秘密の判定の「見逃し」と「誤判定」を数える（#30。`SecretDetectorBench`）。判定を変えるときは、変える前と後で流して比べる。
# 見逃しは種を決めた乱数トークン、誤判定は合成した UUID・ハッシュ・Base64 の画像と、Mac の SDK のヘッダー・ファイル名、
# このリポジトリの文書と Sources/ の Swift で数える。出すのは件数と割合だけ（値は出さない）。
#
#   scripts/secret-bench.sh                       # 表を出す
#   SHOW='識別子（SDK）' scripts/secret-bench.sh   # その種類の誤判定の例も出す（秘密でない公開の文字列だけ）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export MAKURIP_SECRET_BENCH=1
MAKURIP_SECRET_BENCH_SDK="$(xcrun --show-sdk-path)"
export MAKURIP_SECRET_BENCH_SDK
export MAKURIP_SECRET_BENCH_REPO="$ROOT"
export MAKURIP_SECRET_BENCH_SHOW="${SHOW:-}"
swift test --filter SecretDetectorBench 2>&1 | grep -E '^BENCH' | sed -E 's/^BENCH\|//; s/^BENCH-EXAMPLE\|/  例|/'
