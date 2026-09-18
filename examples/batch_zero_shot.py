#!/usr/bin/env python
"""zero-shot 全篇合成示例：逐行台本 + 指定行加抽 take。

用法：先在 deploy.sh 部署好的环境里
  PYTHONPATH 需含 CosyVoice 与 Matcha-TTS（见 02_synthesize.py 的写法）
"""
import sys, time
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BASE / "CosyVoice/third_party/Matcha-TTS"))
sys.path.insert(0, str(BASE / "CosyVoice"))

import torch, torchaudio
from cosyvoice.cli.cosyvoice import CosyVoice3 as Engine

PREFIX = "You are a helpful assistant.<|endofprompt|>"
# 参考音频的精确转写（whisper small 转写 + 人工核对）
TRANSCRIPT = "参考音频里逐字说的那句话，标点也尽量保留。"
# 参考音频：从语音起点开始裁剪、与转写对齐的 3~10 秒片段
REF = str(BASE / "audio/reference/ref.wav")
OUT = BASE / "audio/raw_batch"

lines = [l.strip() for l in (BASE / "台本示例.txt").read_text(encoding="utf-8").splitlines()
         if l.strip() and not l.strip().startswith("#")]

# 重点句加抽：第 2、4 行各多抽 2 条 take（试听后挑最好的替换 seg_XX.wav）
EXTRA = {2: ["t2", "t3"], 4: ["t2", "t3"]}

print("加载模型...", flush=True)
cv = Engine(model_dir=str(BASE / "models/Fun-CosyVoice3-0.5B"))
prompt_text = PREFIX + TRANSCRIPT

def synth(text):
    chunks = cv.inference_zero_shot(text, prompt_text, REF)
    return torch.cat([c["tts_speech"] for c in chunks], dim=1)

manifest = []
for idx, text in enumerate(lines, 1):
    t = time.time()
    try:
        wav = synth(text)
        dst = OUT / f"seg_{idx:02d}.wav"
        torchaudio.save(str(dst), wav, cv.sample_rate)
        manifest.append(f"{dst.name}\t{wav.shape[1]/cv.sample_rate:.2f}\t{text}")
        print(f"[{idx:02d}] {wav.shape[1]/cv.sample_rate:5.2f}s / {time.time()-t:4.0f}s  {text[:24]}", flush=True)
    except Exception as e:
        print(f"[{idx:02d}] 失败: {e}", flush=True)
    if idx in EXTRA:
        for name in EXTRA[idx]:
            t = time.time()
            try:
                wav = synth(text)
                torchaudio.save(str(OUT / f"seg_{idx:02d}_{name}.wav"), wav, cv.sample_rate)
                print(f"    [seg_{idx:02d}_{name}] {wav.shape[1]/cv.sample_rate:.2f}s", flush=True)
            except Exception as e:
                print(f"    [seg_{idx:02d}_{name}] 失败: {e}", flush=True)

(OUT / "manifest.txt").write_text("\n".join(manifest) + "\n", encoding="utf-8")
print(f"\n完成：{OUT}")
