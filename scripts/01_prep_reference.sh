#!/usr/bin/env bash
# 把原料加工成本地克隆模型要的参考音频。
#
# 输出规格：24 kHz / 单声道 / 16 bit PCM WAV，首尾静音已去，响度已归一。
#
# 用法:
#   ./01_prep_reference.sh <素材> [-s 起始秒] [-d 时长秒] [--separate] [-n 名称]
#
# 例:
#   ./01_prep_reference.sh audio/raw/output_clip.mp4 -s 12.5 -d 8 -n ref
#   ./01_prep_reference.sh audio/raw/ep01.mp4 -s 30 -d 6 --separate -n ref_ep01
#
# 参数:
#   -s, --start     从第几秒开始切（默认 0，即从文件开头）
#   -d, --duration  切多长（默认 8 秒；模型建议 3–10 秒）
#   --separate      先做一次人声分离（原片有配乐时用，需要 demucs）
#   -n, --name      输出文件名（默认 ref）

set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF_DIR="$BASE/audio/reference"
mkdir -p "$REF_DIR"

IN=""; START=""; DUR="8"; NAME="ref"; SEPARATE=0

while [ $# -gt 0 ]; do
  case "$1" in
    -s|--start)    START="$2"; shift 2 ;;
    -d|--duration) DUR="$2";   shift 2 ;;
    -n|--name)     NAME="$2";  shift 2 ;;
    --separate)    SEPARATE=1; shift ;;
    -h|--help)     sed -n '2,18p' "$0"; exit 0 ;;
    -*)            echo "未知参数：$1"; exit 1 ;;
    *)             IN="$1"; shift ;;
  esac
done

[ -n "$IN" ] || { echo "用法: $0 <素材> [-s 起始秒] [-d 时长秒] [--separate] [-n 名称]"; exit 1; }
[ -f "$IN" ] || { echo "找不到文件：$IN"; exit 1; }
command -v ffmpeg >/dev/null || { echo "未找到 ffmpeg"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[1/4] 抽出音轨"
ffmpeg -hide_banner -loglevel error -y -i "$IN" \
  -vn -ac 1 -ar 24000 -c:a pcm_s16le "$TMP/step1.wav"

SRC="$TMP/step1.wav"

if [ "$SEPARATE" = "1" ]; then
  echo "[2/4] 人声分离（demucs，第一次会下模型）"
  DEMUCS=""
  command -v demucs >/dev/null && DEMUCS="demucs"
  [ -z "$DEMUCS" ] && [ -x "$BASE/.venv/bin/demucs" ] && DEMUCS="$BASE/.venv/bin/demucs"
  [ -n "$DEMUCS" ] || { echo "未找到 demucs。先执行： $BASE/.venv/bin/pip install demucs"; exit 1; }
  "$DEMUCS" --two-stems=vocals -n htdemucs -o "$TMP/demucs" "$TMP/step1.wav" 2>&1 | tail -3
  SRC="$(find "$TMP/demucs" -name 'vocals.wav' | head -1)"
  [ -n "$SRC" ] || { echo "人声分离失败，没有产出 vocals.wav"; exit 1; }
else
  echo "[2/4] 跳过人声分离（原片本身干净就用这个）"
fi

echo "[3/4] 裁剪 $DUR 秒 + 去首尾静音 + 响度归一化"
CUT=()
[ -n "$START" ] && CUT=(-ss "$START")
ffmpeg -hide_banner -loglevel error -y "${CUT[@]}" -t "$DUR" -i "$SRC" \
  -af "silenceremove=start_periods=1:start_silence=0.02:start_threshold=-45dB:detection=peak,\
areverse,\
silenceremove=start_periods=1:start_silence=0.02:start_threshold=-45dB:detection=peak,\
areverse,\
loudnorm=I=-20:TP=-2:LRA=11" \
  -ac 1 -ar 24000 -c:a pcm_s16le "$REF_DIR/${NAME}.wav"

echo "[4/4] 产出自检"
ffprobe -v error \
  -show_entries stream=sample_rate,channels,bits_per_sample \
  -show_entries format=duration \
  -of default=noprint_wrappers=1 "$REF_DIR/${NAME}.wav" \
  | sed 's/^/      /'

echo
echo "完成：$REF_DIR/${NAME}.wav"
echo "试听：  afplay \"$REF_DIR/${NAME}.wav\""
echo
echo "下一句要确认的事：把这个文件从头到尾听一遍，确认"
echo "  - 里面只有目标角色一个人在说话"
echo "  - 没有音乐、没有音效、没有其他人的声音叠进来"
echo "  - 时长在 3–10 秒之间（脚本会自己截，但太短说明起点选得不好）"
