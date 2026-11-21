#!/bin/zsh
# 下载器回归测试一键脚本：生成测试文件 → 起本地服务器 → 编译 harness → 跑全部场景
# 用法: ./run.sh          （在 tools/download-harness 目录下执行）
set -u
cd "$(dirname "$0")"

DL_SRC="../../APP/Services/Download/SegmentedIPADownloader.swift"
TMP_DIR=".harness_tmp"
SIZE_BYTES=$((100 * 1024 * 1024))

fail() { echo "FAIL: $1"; exit 1; }

[[ -f "$DL_SRC" ]] || fail "找不到 $DL_SRC（请在项目根目录的 tools/download-harness 下运行）"

command -v swiftc >/dev/null || fail "需要 swiftc（请安装 Xcode 命令行工具）"
command -v python3 >/dev/null || fail "需要 python3"

mkdir -p "$TMP_DIR"
echo "==> 生成 100MB 测试文件"
head -c $SIZE_BYTES /dev/null 2>/dev/null
head -c $SIZE_BYTES /dev/urandom > "$TMP_DIR/big.bin" || fail "生成测试文件失败"
EXPECTED=$(md5 -q "$TMP_DIR/big.bin")
echo "    source md5=$EXPECTED"

cleanup() { pkill -f "RangeServer.py" 2>/dev/null; }
trap cleanup EXIT

echo "==> 启动本地测试服务器（5 个端口/模式）"
python3 RangeServer.py 18999 "$TMP_DIR/big.bin"                  >/dev/null 2>&1 &
python3 RangeServer.py 18998 "$TMP_DIR/big.bin" --no-range       >/dev/null 2>&1 &
python3 RangeServer.py 18997 "$TMP_DIR/big.bin" --throttle-ms=2  >/dev/null 2>&1 &
python3 RangeServer.py 18996 "$TMP_DIR/big.bin" --throttle-ms=2  >/dev/null 2>&1 &
python3 RangeServer.py 18995 "$TMP_DIR/big.bin" --throttle-ms=20 >/dev/null 2>&1 &
python3 RangeServer.py 18994 "$TMP_DIR/big.bin" --throttle-ms=2 --probe-delay-ms=1500 >/dev/null 2>&1 &
python3 RangeServer.py 18992 "$TMP_DIR/big.bin" --stall-after-bytes=262144 >/dev/null 2>&1 &
sleep 0.5

echo "==> 编译 harness"
swiftc -O -parse-as-library -o "$TMP_DIR/testrun" harness.swift "$DL_SRC" 2>&1 | grep -E "[0-9]+:[0-9]+: error:" && fail "编译失败"

# 每个阶段只跑一次，输出存日志供检查。用法: run_phase <日志名> <testrun 阶段参数>
run_phase() {
  local name=$1
  local phase=$2
  "$TMP_DIR/testrun" "$phase" > "$TMP_DIR/log_$name.txt" 2>&1
  local rc=$?
  grep -E "^\[(die|resume|probe-pause|probe-cancel|segmented|fallback|cancel|pause|cancelresume)\]|ALL TESTS" "$TMP_DIR/log_$name.txt"
  return $rc
}
phase_passed() {
  local log="$TMP_DIR/log_$1.txt"
  grep -q "ALL TESTS PASSED" "$log" && ! grep -q "FAIL" "$log"
}

overall=0

echo "==> 基础套件（分段 / 回退 / 取消 / 暂停恢复 / 取消续传）"
run_phase base all || overall=1
phase_passed base || overall=1

echo "==> 模拟进程被杀 → 断点续传"
# die 阶段成功与否以退出码判定（成功才 exit(0)）
run_phase die die || overall=1
run_phase resume resume || overall=1
phase_passed resume || overall=1

echo "==> 断点文件损坏 → 自动回退全新下载"
run_phase corrupt corrupt || overall=1
phase_passed corrupt || overall=1

echo "==> 探测窗口期暂停/取消边界"
run_phase probedge probedge || overall=1
phase_passed probedge || overall=1

echo "==> 传输停滞看门狗（服务器扣住连接不发数据）"
run_phase stall stall || overall=1
phase_passed stall || overall=1

if [[ $overall -eq 0 ]]; then
  rm -rf "$TMP_DIR"
  echo "==> 全部场景通过 ✅"
else
  echo "==> 存在失败场景 ❌（诊断日志保留在 $TMP_DIR/log_*.txt）"
fi
exit $overall
