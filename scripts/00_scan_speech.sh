#!/usr/bin/env bash
# 扫描素材，打印所有“连续人声区间”，用来挑出适合做克隆样本的片段。
#
# 用法:
#   ./00_scan_speech.sh <素材文件> [噪声阈值dB] [最短静音秒数]
#
# 例:
#   ./00_scan_speech.sh audio/raw/ep01.mp4
#   ./00_scan_speech.sh audio/raw/ep01.mp4 -38 0.8
#
# 原片带背景音乐时，先跑 01_prep_reference.sh --separate 做人声分离，
# 再对这个分离结果二次扫描，阈值会准得多。

set -euo pipefail

IN="${1:?用法: $0 <素材文件> [噪声阈值dB=-32] [最短静音秒数=1.2]}"
NOISE="${2:--32}"
MINDUR="${3:-1.2}"

[ -f "$IN" ] || { echo "找不到文件：$IN"; exit 1; }
command -v ffmpeg >/dev/null || { echo "未找到 ffmpeg"; exit 1; }

printf '素材：%s\n' "$IN"
ffprobe -v error -show_entries format=duration -of csv=p=0 "$IN" \
  | awk '{ printf "总时长：%.1f 秒\n", $1 }'
printf '\n人声区间：\n'
printf -- '-------------------------------------------------\n'

ffmpeg -hide_banner -nostats -i "$IN" \
  -af "silencedetect=noise=${NOISE}dB:d=${MINDUR}" -f null - 2>&1 \
| awk '
  /silence_start/ {
    split($0, a, "silence_start: "); s = a[2] + 0
    if (s - prev > 0.3) printf "  %7.2f  →  %7.2f     时长 %5.2f 秒\n", prev, s, s - prev
    prev = s
  }
  /silence_end/ { split($0, a, "silence_end: "); prev = a[2] + 0 }
  END {
    split($0, a, "silence_end: "); e = a[2] + 0
  }
'

printf -- '-------------------------------------------------\n'
printf '挑选建议：3–10 秒、前后各有 0.3 秒以上静音、只有一个人在说话。\n'
printf '带 BGM 的素材阈值要放宽到 -25 ~ -20dB，否则切出来的段会连配乐一起带上。\n'
