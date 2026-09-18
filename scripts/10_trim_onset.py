#!/usr/bin/env python
"""切掉片段开头的起音杂音 v4：振幅规则 + 深谷回退。

两类杂音形态：
  A. 安静型："啊"衰减 + 气息低于 -25dB → 振幅规则（首个 RMS > -25dB
     持续 80ms 的帧即首词起音）直接命中。
  B. 响亮型："啊"本身 ≥-25dB（seg_03/seg_08）→ 振幅规则失效（切 0s），
     回退深谷规则：前 0.8s 内找第一个持续 ≥30ms、低于 -35dB 的能量谷，
     谷底结束处即真实首词起点。

用法：.venv/bin/python scripts/10_trim_onset.py <输入目录> <输出目录>
"""
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

BASE = Path(__file__).resolve().parent.parent
SRC = Path(sys.argv[1]) if len(sys.argv) > 1 else BASE / "audio/raw_run1"
DST = Path(sys.argv[2]) if len(sys.argv) > 2 else BASE / "audio/raw_run1_trim"
DST.mkdir(parents=True, exist_ok=True)

FRAME_MS = 10
SEARCH_S = 0.8
SPEECH_DB = -25.0
SPEECH_RUN_FRAMES = 8
DIP_DB = -35.0
DIP_RUN_FRAMES = 3
MAX_CUT_S = 0.8


def frame_rms(wav, sr, upto_s):
    frame = int(sr * FRAME_MS / 1000)
    out = []
    for i in range(0, min(int(sr * upto_s) + frame, len(wav)), frame):
        c = wav[i:i + frame]
        out.append(20 * np.log10(float(np.sqrt(np.mean(c ** 2))) + 1e-12))
    return out


def first_speech_onset(rms):
    run = 0
    for j, db in enumerate(rms):
        if db > SPEECH_DB:
            run += 1
            if run >= SPEECH_RUN_FRAMES:
                return j - SPEECH_RUN_FRAMES + 1
        else:
            run = 0
    return None


def first_deep_valley_end(rms):
    """返回谷底结束帧（能量重新升过 DIP_DB 的位置），无则 None。"""
    run = 0
    for j, db in enumerate(rms):
        if db < DIP_DB:
            run += 1
        else:
            if run >= DIP_RUN_FRAMES:
                return j
            run = 0
    return None


for f in sorted(SRC.glob("seg_*.wav")):
    wav, sr = sf.read(f, dtype="float32")
    if wav.ndim > 1:
        wav = wav.mean(axis=1)
    rms = frame_rms(wav, sr, SEARCH_S)
    frame = int(sr * FRAME_MS / 1000)

    onset = first_speech_onset(rms)
    rule = "振幅"
    cut_at = None
    if onset is not None:
        candidate = onset * frame - int(sr * 0.03)
        if candidate / sr >= 0.10:
            cut_at = candidate

    if cut_at is None:  # 振幅规则未命中或命中过晚（杂音响亮），走深谷回退
        vend = first_deep_valley_end(rms)
        if vend is not None and vend > 0:
            cut_at = vend * frame - int(sr * 0.01)
            rule = "深谷"

    if cut_at is None or cut_at <= 0:
        print(f"[{f.name}] 未检出可切结构，保留原样")
        sf.write(DST / f.name, wav, sr)
        continue
    if cut_at / sr > MAX_CUT_S:
        print(f"[{f.name}] 切割量 {cut_at / sr:.2f}s 超保护上限，保留原样")
        sf.write(DST / f.name, wav, sr)
        continue
    out = wav[cut_at:].copy()
    fade = min(int(sr * 0.005), len(out))
    out[:fade] *= np.linspace(0, 1, fade)
    sf.write(DST / f.name, out, sr)
    print(f"[{f.name}] 切掉开头 {cut_at / sr:.2f}s（{rule}规则）")
