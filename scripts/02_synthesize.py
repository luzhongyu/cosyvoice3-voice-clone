#!/usr/bin/env python
"""用本地 CosyVoice 做零样本音色克隆合成。

两条路径，默认走第一条：

  cross-lingual（默认）  只喂参考音频，不需要参考音频的转写文字。
                         手上只有台本、没有原片字幕时直接用它。

  zero-shot（--prompt-text）
                         额外提供参考音频对应的文字，说话人相似度会再高一点。
                         适合原片字幕容易拿到的情况。

台本文本按行切分，每一行合成一个独立片段，
段间的留白由 03_postprocess.sh 统一控制，方便单独重做某一句。
"""

import argparse
import os
import sys
import time
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
REPO = BASE / "CosyVoice"
DEFAULT_MODEL = BASE / "models" / "Fun-CosyVoice3-0.5B"

if not REPO.is_dir():
    sys.exit(f"找不到 CosyVoice 仓库：{REPO}\n先跑 ./install.sh")

sys.path.insert(0, str(REPO / "third_party" / "Matcha-TTS"))
sys.path.insert(0, str(REPO))

import torch  # noqa: E402
import torchaudio  # noqa: E402

# CosyVoice3 入口类是 CosyVoice3（仓库里也有 AutoModel 可自动判型）。
try:
    from cosyvoice.cli.cosyvoice import CosyVoice3 as Engine
except ImportError:  # 老版本仓库兜底
    from cosyvoice.cli.cosyvoice import AutoModel as Engine  # type: ignore

# CosyVoice3 的 LLM 要求文本流里必须出现 <|endofprompt|>（token 151646），
# 前端不会自动加，需要调用方自带前缀（见 CosyVoice/example.py 官方示例）。
# 这个位置同时也是给模型的风格指令位，例如"用兴奋的语气说：<|endofprompt|>"。
CV3_TEXT_PREFIX = "You are a helpful assistant.<|endofprompt|>"


def parse_args():
    p = argparse.ArgumentParser(
        description="CosyVoice 零样本音色克隆",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--script", help="台本文件，每行一个片段")
    src.add_argument("--text", help="直接给一段文本（单片段）")

    p.add_argument("--ref", default=str(BASE / "audio/reference/ref1.wav"),
                   help="参考音频（默认 ref1.wav，A/B 试听择优）")
    p.add_argument("--prompt-text", default="",
                   help="参考音频对应的文字；给了就走 zero-shot，不给走 cross-lingual")
    p.add_argument("--model", default=str(DEFAULT_MODEL), help="模型目录")
    p.add_argument("--out-dir", default=str(BASE / "audio/raw"), help="片段输出目录")
    p.add_argument("--spk-id", default="",
                   help="复用已保存的音色 id；首次用 --save-spk 保存")
    p.add_argument("--save-spk", action="store_true",
                   help="把参考音频的音色存下来，之后可用 --spk-id 复用（需 --prompt-text）")
    return p.parse_args()


def split_script(path):
    lines = []
    for raw in Path(path).read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        lines.append(line)
    return lines


def main():
    args = parse_args()

    ref = Path(args.ref)
    if not ref.is_file():
        sys.exit(f"找不到参考音频：{ref}\n先跑 scripts/01_prep_reference.sh")

    model_dir = Path(args.model)
    if not model_dir.is_dir():
        sys.exit(f"找不到模型目录：{model_dir}\n先跑 ./install.sh 下载模型")

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.script:
        segments = split_script(args.script)
        if not segments:
            sys.exit(f"台本文件里没有可用内容：{args.script}")
    else:
        segments = [args.text]

    mode = "zero-shot" if args.prompt_text else "cross-lingual"
    is_cv3 = Engine.__name__ == "CosyVoice3"
    print(f"模式      : {mode}")
    print(f"引擎      : {Engine.__name__}{'（文本将加 <|endofprompt|> 前缀）' if is_cv3 else ''}")
    print(f"参考音频  : {ref}")
    print(f"模型      : {model_dir}")
    print(f"片段数    : {len(segments)}")
    print(f"计算后端  : {'cuda' if torch.cuda.is_available() else 'cpu'}")
    print()

    print("加载模型（首次约 30 秒）...")
    t0 = time.time()
    cosyvoice = Engine(model_dir=str(model_dir))
    sr = cosyvoice.sample_rate
    print(f"加载完成，{time.time() - t0:.1f} 秒；输出采样率 {sr} Hz\n")

    if args.save_spk:
        if not args.prompt_text:
            sys.exit("--save-spk 需要同时提供 --prompt-text")
        spk_id = args.spk_id or "output"
        assert cosyvoice.add_zero_shot_spk(args.prompt_text, str(ref), spk_id) is True
        cosyvoice.save_spkinfo()
        print(f"音色已保存：{spk_id}\n")

    manifest = []
    failed = []
    total_audio = 0.0
    total_wall = 0.0

    for idx, text in enumerate(segments, 1):
        dst = out_dir / f"seg_{idx:02d}.wav"
        synth_text = CV3_TEXT_PREFIX + text if (is_cv3 and not args.prompt_text) else text
        # zero-shot 模式下前缀加在 prompt_text 上（官方 example.py 的用法）
        zero_prompt = CV3_TEXT_PREFIX + args.prompt_text if (is_cv3 and args.prompt_text) else args.prompt_text
        print(f"[{idx:02d}] 合成中：{text[:30]}", flush=True)
        t = time.time()
        try:
            if args.prompt_text:
                chunks = cosyvoice.inference_zero_shot(
                    synth_text, zero_prompt, str(ref),
                    zero_shot_spk_id=args.spk_id,
                )
            else:
                chunks = cosyvoice.inference_cross_lingual(synth_text, str(ref))
            wavs = [c["tts_speech"] for c in chunks]
            if not wavs or all(w.shape[1] == 0 for w in wavs):
                raise RuntimeError("合成结果为空（0 帧）")
            wav = torch.cat(wavs, dim=1)
        except Exception as exc:  # noqa: BLE001
            print(f"[{idx:02d}] 失败：{type(exc).__name__}: {exc}", flush=True)
            failed.append((idx, text, str(exc)))
            continue

        torchaudio.save(str(dst), wav, sr)
        dur = wav.shape[1] / sr
        wall = time.time() - t
        total_audio += dur
        total_wall += wall
        manifest.append(f"{dst.name}\t{dur:.2f}\t{text}")
        print(f"[{idx:02d}] {dur:5.2f} 秒音频 / {wall:5.1f} 秒耗时  {text[:28]}")

    (out_dir / "manifest.txt").write_text("\n".join(manifest) + "\n", encoding="utf-8")

    print()
    if failed:
        print(f"{len(failed)} 段失败：")
        for idx, text, err in failed:
            print(f"  [{idx:02d}] {text[:30]}  <-  {err[:80]}")
    print(f"成功 {len(manifest)} 段，音频合计 {total_audio:.1f} 秒，耗时 {total_wall:.1f} 秒")
    if total_audio:
        print(f"实时率 RTF = {total_wall / total_audio:.2f}（小于 1 表示比实时快）")
    print(f"片段目录：{out_dir}")
    print("下一步：./scripts/03_postprocess.sh")


if __name__ == "__main__":
    main()
