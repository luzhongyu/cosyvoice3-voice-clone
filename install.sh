#!/usr/bin/env bash
# 建本地推理环境 + 下模型。幂等，可以重复跑。
#
# 用法:
#   ./install.sh                # 建环境 + 下模型
#   ./install.sh --skip-model   # 只建环境
#   ./install.sh --only-model   # 只下模型
#
# 环境落在本项目 .venv 下，不碰系统 Python、不碰全局 site-packages。
# 解释器自动选本机已有的 3.11 / 3.10 / 3.12，不会去 GitHub 现下。

set -uo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$BASE/.venv"
PY="$VENV/bin/python"
REPO="$BASE/CosyVoice"
MODEL_DIR="$BASE/models/Fun-CosyVoice3-0.5B"
MODEL_ID="FunAudioLLM/Fun-CosyVoice3-0.5B-2512"
PYVER="auto"

SKIP_MODEL=0
ONLY_MODEL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-model) SKIP_MODEL=1; shift ;;
    --only-model) ONLY_MODEL=1; shift ;;
    --py)         PYVER="$2"; shift 2 ;;
    -h|--help)    sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数：$1"; exit 1 ;;
  esac
done

die() { echo; echo "失败：$*" >&2; exit 1; }

# 关掉 pip 的 HTTP 缓存和版本自检。
# 原因：本机环境对 os.remove 有批量删除保护，pip 清理缓存时会被拦下来报 SystemExit。
# 关掉缓存后 pip 不再走那条删除路径，装包就正常了。
export PIP_NO_CACHE_DIR=1
export PIP_DISABLE_PIP_VERSION_CHECK=1

# ---------------------------------------------------------------- 依赖检查
command -v ffmpeg >/dev/null || die "缺 ffmpeg。装一下：brew install ffmpeg"

if ! command -v uv >/dev/null; then
  die "缺 uv。装一下：brew install uv
（本项目用 uv 管 Python 环境，不依赖 conda。CosyVoice 官方文档写的是 conda，
  但 uv 等价且更轻，能直接调到 3.10 解释器。）"
fi

[ -d "$REPO/.git" ] || die "找不到 $REPO。
先执行：git clone --recursive https://github.com/FunAudioLLM/CosyVoice.git"

# ---------------------------------------------------------------- 环境
if [ "$ONLY_MODEL" = "0" ]; then
  # 选解释器。官方文档要求 3.10，但 uv 去 GitHub 下 3.10 在国内经常卡死，
  # 所以优先用本机已经有的版本：3.11 与 3.10 的 wheel 覆盖率基本一致，
  # torch 2.3.1 有 cp311 的 macOS arm64 wheel，能直接用。
  if [ "$PYVER" = "auto" ]; then
    for v in 3.11 3.10 3.12; do
      if UV_PYTHON_DOWNLOADS=never uv python find "$v" >/dev/null 2>&1; then
        PYVER="$v"
        break
      fi
    done
    [ "$PYVER" = "auto" ] && die "本机没有 3.10/3.11/3.12 任一解释器。
装一个再重试：  brew install python@3.11
（不建议让 uv 现下 3.10，GitHub release 在国内大概率拉不动。）"
  fi

  PYBIN="$(UV_PYTHON_DOWNLOADS=never uv python find "$PYVER" 2>/dev/null)"
  [ -n "$PYBIN" ] || die "找不到 Python $PYVER 的解释器。换一个版本：./install.sh --py 3.12"

  echo "==> [1/4] 创建虚拟环境：$VENV"
  echo "    解释器：$PYBIN ($("$PYBIN" -V 2>&1))"
  if [ -x "$VENV/bin/python" ]; then
    echo "    已存在，复用"
  else
    # --seed 让 uv 在虚拟环境里装上 pip/setuptools/wheel，否则没有 pip 可用
    uv venv --seed --python "$PYBIN" "$VENV" || die "创建虚拟环境失败"
  fi

  "$PY" -m pip --version >/dev/null 2>&1 || "$PY" -m ensurepip --upgrade >/dev/null 2>&1 || true
  "$PY" -m pip --version >/dev/null 2>&1 || die "虚拟环境里没有 pip。删掉 .venv 重跑本脚本。"

  echo "==> [2/4] 安装 PyTorch 2.3.1（仓库锁定的版本）"
  "$PY" -m pip install --no-cache-dir --disable-pip-version-check --quiet --upgrade pip
  "$PY" -m pip install --no-cache-dir --disable-pip-version-check --quiet \
    torch==2.3.1 torchaudio==2.3.1 \
    || die "PyTorch 安装失败"

  echo "==> [3/4] 安装其余依赖（逐个装，失败项单独报告）"
  REQ="$BASE/.requirements.macos.txt"
  grep -v '^--extra-index-url' "$REPO/requirements.txt" > "$REQ"
  PLOG=/tmp/pip.log
  : > "$PLOG"

  FAILED=()
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | sed 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    case "$line" in
      torch==*|torchaudio==*) continue ;;
      *linux*) continue ;;
    esac
    name="${line%%==*}"
    printf '    %-28s' "$name"
    if "$PY" -m pip install --no-cache-dir --disable-pip-version-check --quiet "$line" >>"$PLOG" 2>&1; then
      echo "OK"
    else
      echo "失败"
      FAILED+=("$line")
    fi
  done < "$REQ"

  if [ ${#FAILED[@]} -gt 0 ]; then
    echo
    echo "    以下 $((${#FAILED[@]})) 项没装上（多为仅训练/评测才用到，通常不影响推理）："
    printf '      - %s\n' "${FAILED[@]}"
    echo "    安装日志：$PLOG"
  fi

  echo "==> 冒烟测试：能否导入 cosyvoice"
  if (cd "$REPO" && "$VENV/bin/python" - <<'PY'
import sys, pathlib
sys.path.insert(0, str(pathlib.Path.cwd() / "third_party" / "Matcha-TTS"))
sys.path.insert(0, str(pathlib.Path.cwd()))
import cosyvoice.cli.cosyvoice as c
print("    cosyvoice 导入正常")
PY
  ); then
    :
  else
    echo "    警告：cosyvoice 导入失败，先看 /tmp/pip.log。"
    echo "    常见原因是 third_party/Matcha-TTS 子模块没拉下来，可执行："
    echo "      git -C $REPO submodule update --init --recursive"
    echo "      # 或直接克隆：git clone --depth 1 https://github.com/shivammehta25/Matcha-TTS.git $REPO/third_party/Matcha-TTS"
    echo "    继续往下走，不影响装模型。"
  fi
fi

# ---------------------------------------------------------------- 模型
if [ "$SKIP_MODEL" = "0" ]; then
  echo "==> [4/4] 下载模型 $MODEL_ID（约 2 GB，走 ModelScope）"
  if [ -d "$MODEL_DIR" ] && [ -n "$(ls -A "$MODEL_DIR" 2>/dev/null)" ]; then
    echo "    已存在，跳过"
  else
    "$PY" -m pip install --no-cache-dir --disable-pip-version-check --quiet modelscope || die "modelscope 安装失败"
    "$PY" - "$MODEL_ID" "$MODEL_DIR" <<'PY' || die "模型下载失败"
import sys
from modelscope import snapshot_download
snapshot_download(sys.argv[1], local_dir=sys.argv[2])
print("    模型就位：", sys.argv[2])
PY
  fi
fi

echo
echo "完成。下一步："
echo "  1. 把素材丢进 audio/raw/，跑 ./scripts/00_scan_speech.sh <素材> 找人声区间"
echo "  2. ./scripts/01_prep_reference.sh <素材> -s <起点> -d 8  生成参考音频"
echo "  3. 写好台本，跑 .venv/bin/python scripts/02_synthesize.py --script 台本.txt"
echo "  4. ./scripts/03_postprocess.sh -n 成品名"
