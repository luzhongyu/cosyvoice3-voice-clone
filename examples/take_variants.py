#!/usr/bin/env python
"""单句多 take 抽卡示例：同一句话生成 N 条，试听挑最好的。

还可以做文本变体：拼音标注 [d][uō]（声母+带调韵母）可锁定读音，
但会扰动整句节奏，仅作兜底。
"""
import sys, time
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BASE / "CosyVoice/third_party/Matcha-TTS"))
sys.path.insert(0, str(BASE / "CosyVoice"))

import torch, torchaudio
from cosyvoice.cli.cosyvoice import CosyVoice3 as Engine

PREFIX = "You are a helpful assistant.<|endofprompt|>"
TRANSCRIPT = "参考音频里逐字说的那句话。"
REF = str(BASE / "audio/reference/ref.wav")
OUT = BASE / "audio/takes_example"
OUT.mkdir(parents=True, exist_ok=True)

LINE = "你好呀！今天也要元气满满哦。"

print("加载模型...", flush=True)
cv = Engine(model_dir=str(BASE / "models/Fun-CosyVoice3-0.5B"))
prompt_text = PREFIX + TRANSCRIPT

for i in (1, 2, 3):
    t = time.time()
    chunks = cv.inference_zero_shot(LINE, prompt_text, REF)
    wav = torch.cat([c["tts_speech"] for c in chunks], dim=1)
    torchaudio.save(str(OUT / f"take_{i}.wav"), wav, cv.sample_rate)
    print(f"[take_{i}] {wav.shape[1]/cv.sample_rate:.2f}s / {time.time()-t:.0f}s", flush=True)
