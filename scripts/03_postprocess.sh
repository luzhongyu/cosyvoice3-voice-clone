#!/usr/bin/env bash
# 把 02_synthesize.py 产出的片段拼成成品。
#
# 流程：统一格式 → 段间插留白 → 拼接 → 响度归一化 → 首尾淡入淡出 → 可选混 BGM → 导出
#
# 用法:
#   ./03_postprocess.sh [-n 成品名] [-g 段间留白秒] [-b BGM文件] [--bgm-gain dB] [-d 片段目录]
#
# 例:
#   ./03_postprocess.sh -n output_morning
#   ./03_postprocess.sh -n output_morning -g 0.5 -b audio/bgm/calm.mp3 --bgm-gain -24
#   ./03_postprocess.sh -n my_first_voice -d audio/raw_run1_trim

set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAW="$BASE/audio/raw"
OUT="$BASE/audio/out"
mkdir -p "$OUT"

NAME="output"
GAP="0.35"
BGM=""
BGM_GAIN="-26"
SR=24000
LUFS="-16"

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--name)     NAME="$2";     shift 2 ;;
    -g|--gap)      GAP="$2";      shift 2 ;;
    -b|--bgm)      BGM="$2";      shift 2 ;;
    --bgm-gain)    BGM_GAIN="$2"; shift 2 ;;
    -l|--lufs)     LUFS="$2";     shift 2 ;;
    -d|--raw-dir)  RAW="$2";      shift 2 ;;
    -h|--help)     sed -n '2,15p' "$0"; exit 0 ;;
    *)             echo "未知参数：$1"; exit 1 ;;
  esac
done

# 相对路径锚定到项目根
case "$RAW" in
  /*) ;;
  *)  RAW="$BASE/$RAW" ;;
esac

command -v ffmpeg >/dev/null || { echo "未找到 ffmpeg"; exit 1; }

shopt -s nullglob
SEGS=("$RAW"/seg_*.wav)
[ ${#SEGS[@]} -gt 0 ] || { echo "在 $RAW 下没找到 seg_*.wav，先跑 scripts/02_synthesize.py"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[1/5] 统一格式（24 kHz / 单声道 / 16 bit），共 ${#SEGS[@]} 段"
n=0
for f in "${SEGS[@]}"; do
  n=$((n + 1))
  ffmpeg -hide_banner -loglevel error -y -i "$f" \
    -ac 1 -ar "$SR" -c:a pcm_s16le "$(printf '%s/n%03d.wav' "$TMP" "$n")"
done

echo "[2/5] 生成 ${GAP} 秒留白"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "anullsrc=r=${SR}:cl=mono" -t "$GAP" -c:a pcm_s16le "$TMP/gap.wav"

LIST="$TMP/list.txt"
: > "$LIST"
first=1
for f in "$TMP"/n*.wav; do
  if [ "$first" -eq 0 ]; then
    printf "file '%s'\n" "$TMP/gap.wav" >> "$LIST"
  fi
  printf "file '%s'\n" "$f" >> "$LIST"
  first=0
done

echo "[3/5] 拼接"
ffmpeg -hide_banner -loglevel error -y \
  -f concat -safe 0 -i "$LIST" -c copy "$TMP/joined.wav"

DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TMP/joined.wav")
FADE_OUT=$(awk -v d="$DUR" 'BEGIN { s = d - 0.4; if (s < 0) s = 0; printf "%.2f", s }')

echo "[4/5] 响度归一化到 ${LUFS} LUFS + 淡入淡出"
ffmpeg -hide_banner -loglevel error -y -i "$TMP/joined.wav" \
  -af "loudnorm=I=${LUFS}:TP=-1.5:LRA=11,afade=in:st=0:d=0.15,afade=out:st=${FADE_OUT}:d=0.4" \
  -ar "$SR" -c:a pcm_s16le "$OUT/${NAME}.wav"

if [ -n "$BGM" ]; then
  [ -f "$BGM" ] || { echo "找不到 BGM：$BGM"; exit 1; }
  echo "[5/5] 混入 BGM（${BGM_GAIN} dB，自动循环到成品长度）"
  ffmpeg -hide_banner -loglevel error -y \
    -i "$OUT/${NAME}.wav" -stream_loop -1 -i "$BGM" \
    -filter_complex "[0:a]aformat=sample_rates=${SR}:channel_layouts=mono[a0];\
[1:a]aformat=sample_rates=${SR}:channel_layouts=mono,volume=${BGM_GAIN}dB,afade=in:st=0:d=1[a1];\
[a1][a0]sidechaincompress=threshold=0.03:ratio=6:attack=20:release=400[bg];\
[bg][a0]amix=inputs=2:duration=first:weights=1 1:normalize=0[mix]" \
    -map "[mix]" -t "$DUR" -ar "$SR" -c:a pcm_s16le "$OUT/${NAME}_mixed.wav"
  mv "$OUT/${NAME}_mixed.wav" "$OUT/${NAME}.wav"
else
  echo "[5/5] 未指定 BGM，跳过混音"
fi

ffmpeg -hide_banner -loglevel error -y -i "$OUT/${NAME}.wav" \
  -codec:a libmp3lame -b:a 192k "$OUT/${NAME}.mp3"

echo
echo "成品："
ffprobe -v error -show_entries format=duration,size -of default=noprint_wrappers=1 "$OUT/${NAME}.mp3" \
  | sed 's/^/      /'
echo
echo "      $OUT/${NAME}.wav   （母带，24 kHz 无损）"
echo "      $OUT/${NAME}.mp3   （成品，192 kbps）"
echo "试听：afplay \"$OUT/${NAME}.mp3\""
