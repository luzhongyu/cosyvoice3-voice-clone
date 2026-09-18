#!/usr/bin/env bash
# 一键部署：环境 + 依赖修补 + 代码 + 模型 + 冒烟验证。幂等，可重复跑。
#
# 用法:
#   ./deploy.sh                # 全流程
#   ./deploy.sh --skip-model   # 跳过模型下载
#   ./deploy.sh --verify-only  # 只做冒烟验证（不装任何东西）
#
# 在 install.sh（建 venv + 装 requirements）的基础上，补齐本机实测
# 缺失的推理依赖，并自动打 diffusers 兼容补丁。

set -uo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$BASE/.venv"
PY="$VENV/bin/python"
REPO="$BASE/CosyVoice"
MATCHA="$REPO/third_party/Matcha-TTS"
MODEL_DIR="$BASE/models/Fun-CosyVoice3-0.5B"
MODEL_ID="FunAudioLLM/Fun-CosyVoice3-0.5B-2512"

SKIP_MODEL=0
VERIFY_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-model)  SKIP_MODEL=1;  shift ;;
    --verify-only) VERIFY_ONLY=1; shift ;;
    -h|--help)     sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "未知参数：$1"; exit 1 ;;
  esac
done

die() { echo; echo "失败：$*" >&2; exit 1; }

export PIP_NO_CACHE_DIR=1
export PIP_DISABLE_PIP_VERSION_CHECK=1

# ---------------------------------------------------------------- 冒烟验证
verify() {
  echo "==> 冒烟验证：完整推理 import 链"
  PYTHONPATH="$MATCHA:$REPO" "$PY" - <<'PY'
from cosyvoice.cli.cosyvoice import CosyVoice3
import diffusers, hydra, lightning, librosa, soundfile, pyarrow
print("    全链 import OK（diffusers %s）" % diffusers.__version__)
PY
  [ -f "$MODEL_DIR/cosyvoice3.yaml" ] && echo "    模型就位：$MODEL_DIR" \
    || echo "    模型缺失，跑 ./deploy.sh 下载"
}

[ -x "$PY" ] || { [ "$VERIFY_ONLY" = "1" ] && die "还没建环境，先跑 ./deploy.sh"; }

if [ "$VERIFY_ONLY" = "1" ]; then
  verify
  exit 0
fi

# ---------------------------------------------------------------- 前置检查
command -v ffmpeg >/dev/null || die "缺 ffmpeg：brew install ffmpeg"
command -v git     >/dev/null || die "缺 git"
command -v uv      >/dev/null || die "缺 uv：brew install uv"

# ---------------------------------------------------------------- 代码
if [ ! -d "$REPO/.git" ]; then
  echo "==> [1/5] 克隆 CosyVoice"
  git clone --depth 1 https://github.com/FunAudioLLM/CosyVoice.git "$REPO" \
    || die "CosyVoice 克隆失败"
fi

if [ ! -f "$MATCHA/matcha/models/components/flow_matching.py" ]; then
  echo "==> [1/5] 克隆 Matcha-TTS 子模块（CosyVoice 的 flow 模块依赖它）"
  git clone --depth 1 https://github.com/shivammehta25/Matcha-TTS.git "$MATCHA" \
    || die "Matcha-TTS 克隆失败"
fi

# ---------------------------------------------------------------- 环境
echo "==> [2/5] 建环境 + 装 requirements（install.sh，幂等）"
"$BASE/install.sh" --skip-model || die "install.sh 失败，看上方输出"

[ -x "$PY" ] || die "虚拟环境不可用：$PY"

# ---------------------------------------------------------------- 推理依赖补齐
echo "==> [3/5] 补齐推理链实测缺失的包"
#   说明：requirements.txt 面向完整仓库（训练+服务），推理路径实际还缺下面这些。
#   envwrap 是 tqdm 4.70 的打包 bug（代码 import 但没声明依赖）。
MISSING=()
for pkg in envwrap hydra-core==1.3.2 lightning==2.2.4 rich==13.7.1 \
           gdown==5.1.0 wget==3.2 librosa==0.10.2 soundfile==0.12.1 \
           pyarrow==18.1.0 pyworld==0.3.4 diffusers==0.25.0; do
  "$PY" -c "import importlib.metadata as m, sys; m.version('${pkg%%==*}')" >/dev/null 2>&1 \
    || MISSING+=("$pkg")
done
if [ ${#MISSING[@]} -eq 0 ]; then
  echo "    全部已装，跳过"
else
  "$PY" -m pip install --no-cache-dir --disable-pip-version-check --quiet \
    "${MISSING[@]}" || die "依赖补齐失败"
  printf '    已安装：%s\n' "${MISSING[*]}"
fi

# ---------------------------------------------------------------- diffusers shim
echo "==> [4/5] 检查 diffusers 兼容补丁"
"$PY" - <<'PY'
import glob, pathlib, sys
import importlib.metadata as md
from packaging.version import Version

v = md.version("diffusers")
cands = glob.glob(str(pathlib.Path(sys.prefix) / "lib" / "python3.*" / "site-packages" / "diffusers" / "utils" / "dynamic_modules_utils.py"))
if not cands:
    print("    未找到 diffusers 安装路径，跳过"); sys.exit(0)
p = pathlib.Path(cands[0])
src = p.read_text()
if "cached_download = None" in src:
    print(f"    补丁已存在（diffusers {v}），跳过"); sys.exit(0)
old = "from huggingface_hub import cached_download, hf_hub_download, model_info"
if old not in src:
    hub = md.version("huggingface_hub")
    if Version(hub) < Version("0.26"):
        print(f"    huggingface_hub {hub} < 0.26，无需补丁"); sys.exit(0)
    raise SystemExit("    diffusers 源码结构与预期不符，需手工检查 " + str(p))
new = ("from huggingface_hub import hf_hub_download, model_info\n\n"
       "try:  # huggingface_hub>=0.26 removed cached_download; only used for community pipelines from GitHub\n"
       "    from huggingface_hub import cached_download\n"
       "except ImportError:  # pragma: no cover\n"
       "    cached_download = None")
p.write_text(src.replace(old, new))
print(f"    已给 diffusers {v} 打上 cached_download 兼容补丁")
PY
[ $? -eq 0 ] || die "diffusers 补丁失败"

# ---------------------------------------------------------------- 模型
if [ "$SKIP_MODEL" = "0" ]; then
  echo "==> [5/5] 模型 $MODEL_ID（约 2 GB，走 ModelScope）"
  if [ -f "$MODEL_DIR/cosyvoice3.yaml" ]; then
    echo "    已存在，跳过"
  else
    "$PY" - "$MODEL_ID" "$MODEL_DIR" <<'PY' || die "模型下载失败"
import sys
from modelscope import snapshot_download
snapshot_download(sys.argv[1], local_dir=sys.argv[2])
print("    模型就位：", sys.argv[2])
PY
  fi
fi

# ---------------------------------------------------------------- 验证
verify

echo
echo "部署完成。产出一条新音频的标准流程："
echo "  1. 编辑台本（每行一个片段，参照 台本示例.txt）"
echo "  2. .venv/bin/python scripts/02_synthesize.py --script 台本.txt \\"
echo "       --ref audio/reference/ref.wav \\"
echo "       --prompt-text \"参考音频的转写文字\" --out-dir audio/raw_新目录"
echo "  3. .venv/bin/python scripts/10_trim_onset.py audio/raw_新目录 audio/raw_新目录_trim"
echo "  4. ./scripts/03_postprocess.sh -n 成品名 -d audio/raw_新目录_trim"
