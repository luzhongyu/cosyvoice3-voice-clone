# cosyvoice3-voice-clone

English | [中文](README-zh.md)

A voice-cloning pipeline that runs entirely on your own machine. It uses CosyVoice 3 for zero-shot / cross-lingual cloning: give it one reference audio clip plus a script, and it produces the finished audio. Fully offline — no material is ever uploaded.

Design decisions and the pitfalls behind them are recorded in **[DESIGN.md](DESIGN.md)** (Chinese only).

---

## What you need before you start

| Requirement | Notes |
|---|---|
| **Voice material to clone** | Audio or video containing the target speaker (TV shows, animation, podcasts, your own recording — anything goes). Key requirement: **one speaker only, continuous speech, and no background music drowning out the voice.** BGM is tolerable and there are ways to handle it later, but the cleaner the voice, the better the result |
| **An Apple Silicon Mac** | M-series chip, 16GB RAM minimum (0.5B model, CPU inference). x86 + GPU should work in theory, but the scripts aren't adapted for it |
| **~2.5GB free disk** | 2GB of model weights + the environment |
| **A working brew** | ffmpeg / uv are installed through brew |
| **~30 minutes** | 15 min for the first deploy (depends on your connection), 10 min for material prep, 5 min for the first synthesis and listen-back |

Expected quality: timbre similarity lands at "very close"; prosody naturalness is a roll of the dice (each line is generated independently, so there's a gacha element — see step 6). On CPU, one minute of audio takes roughly 5–7 minutes to synthesize. It suits short custom pieces of a few minutes; it is not suitable for real-time conversation.

---

## Step 1: Set up the environment (~15 min, once)

```bash
git clone https://github.com/<you>/cosyvoice3-voice-clone.git
cd cosyvoice3-voice-clone
./deploy.sh
```

That single command handles: ffmpeg/uv check → Python virtualenv → PyTorch and all dependencies → cloning the CosyVoice repo and the Matcha-TTS submodule → patching diffusers for compatibility → downloading the 2GB model → smoke test.

You're done when you see `全链 import OK` and `模型就位` (those are the script's literal output strings). Don't panic if an individual package fails to install — the script lists failures separately, most of them don't affect inference, and re-running `./deploy.sh` skips the steps that already succeeded.

Environment only, no model download: `./deploy.sh --skip-model`. Verify an existing install: `./deploy.sh --verify-only`.

## Step 2: Prepare the reference audio (the step that caps your similarity)

The reference audio is the single most important input in the whole pipeline. The goal: cut a **3–10 second** clip of one person speaking continuously, cleanly.

```bash
# 2a. Drop your material into audio/raw/ and scan for stretches where someone is talking
./scripts/00_scan_speech.sh audio/raw/your-material.mp4

# 2b. If the material has background music, separate the vocals first
#     (needs demucs; the script will tell you how to install it)
./scripts/01_prep_reference.sh audio/raw/your-material.mp4 -s 30 -d 8 --separate -n ref

#     No music? Cut directly — 8 seconds starting at the offset you picked from the scan
./scripts/01_prep_reference.sh audio/raw/your-material.mp4 -s 12.5 -d 8 -n ref
```

The output is `audio/reference/ref.wav` (24kHz mono). Three hard requirements:

- **Start the cut exactly at the speech onset.** Breath or a trailing sound from before the onset gets learned as the template for "how a sentence starts", and is then reproduced on every segment as an opening artifact. This is the first line of defense against cause #1 in step 5 — cut this cleanly and you've ruled that class of noise out
- Only one person for the whole clip, uninterrupted (mix in a second speaker and the timbre bleeds)
- Keep it under 30 seconds (there's a hard assertion in the code); 3–10 seconds is the sweet spot

**For zero-shot (recommended), you also need a transcript of this audio.** Use whisper:

```bash
.venv/bin/python -c "
import whisper
r = whisper.load_model('small').transcribe('audio/reference/ref.wav', language='zh')
print(r['text'])
"
```

**Check the transcript word by word afterwards**: whisper gets character names and proper nouns wrong, and sometimes hallucinates prompt text into the beginning. All of that needs manual fixing. If the transcript is off, you lose the similarity advantage that zero-shot buys you.

## Step 3: Write the script

The script is a plain text file, **one segment per line**. See `台本示例.txt` for a working example (the bundled sample is in Chinese):

```
你好呀！我是你的专属通话员，今天也要元气满满哦。
睡前故事时间到了，快躺好，盖好小被子，闭上眼睛。
今天是星期六，天气很好，我们去公园放风筝吧。
```

Rules:

- Break the line wherever you want a pause; a 0.35s gap is inserted between segments automatically
- Don't write parenthetical stage directions (they get read aloud) — control tone through punctuation
- Write numbers out in words ("thirty seconds", not "30s")
- 10–40 characters per line is stable; very short lines (two or three characters) tend to drift in rhythm

## Step 4: Synthesize

```bash
.venv/bin/python scripts/02_synthesize.py --script 台本示例.txt \
  --ref audio/reference/ref.wav \
  --prompt-text "the exact words spoken in the reference audio" \
  --out-dir audio/raw_run1
```

Passing `--prompt-text` selects zero-shot mode (recommended); leaving it out falls back to cross-lingual (no transcript needed, slightly lower similarity). When it finishes you get one `seg_XX.wav` per line in `--out-dir`, plus a `manifest.txt` recording each segment's duration and text.

Speed expectation on CPU: 15–30 seconds to load the model, then roughly 1 minute per 10 seconds of audio.

## Step 5: Handle onset noise (check first, then decide)

Synthesized segments may open with an "ah"-like sound. It doesn't always show up; and when it does, there's more than one possible cause, each needing a different fix:

| Cause | How to tell | What to do |
|---|---|---|
| **Dirty reference-audio onset**: breath, a trailing sound, or the previous sentence bleeds in before the speech onset. Zero-shot learns it as the template for "how a sentence starts", so it gets reproduced on every segment | The noise at the start of each segment is **highly consistent**, and you can find that same sound in the reference audio | Go back to step 2 and re-cut, starting strictly at the speech onset. This one is fixable at the root |
| **Generation-side onset**: the LLM's first speech token carries a vowel onset | The reference audio is already clean, and the noise is **intermittent** and varies in loudness | Can't be fixed — only trimmed in post |

Cause #1 has an architectural basis (see [DESIGN.md](DESIGN.md) §8: the reference audio injects conditioning through three separate paths, and if any one of them is dirty the output reproduces the dirt). Cause #2 **has not been confirmed by a controlled experiment** — §5 explains why. So don't rush to blame yourself; work from the diagnostic column.

**Listen to two or three `seg_XX.wav` files first**: if the openings are clean, skip this step entirely. If there's noise, run:

```bash
.venv/bin/python scripts/10_trim_onset.py audio/raw_run1 audio/raw_run1_trim
```

Segments in the output directory feed straight into the later steps. If every segment still has residue after trimming, go back to the table and confirm the cause from the diagnostic column — in particular, verify that the reference-audio onset is genuinely clean, since that's the only cause with a root-level fix.

## Step 6: Audition each line and re-roll takes

This is where quality control actually happens. **The timbre and rhythm of the same sentence vary between generations** — if you don't like one, generate several more and pick the best, rather than tuning parameters:

```bash
# See examples/take_variants.py: three takes of the same line
.venv/bin/python examples/take_variants.py
```

Audition `audio/takes_example/take_1~3.wav`, pick a winner, and copy it over the corresponding `seg_XX.wav` in the segment directory.

Specific defects have specific fixes — all of them are script edits, not parameter tuning:

| Defect | Fix |
|---|---|
| Two characters run together with no pause | Split into two lines and let the inter-segment gap take over the pause |
| Speaking rate drifts | Merge adjacent short lines into one; change "：" to "，" (colons tend to trigger an announcer tone) |
| A character is read with the wrong tone | Rewrite it as a common homophone (most reliable); or use pinyin annotation `[d][uō]` (locks the pronunciation but disturbs the rhythm of the whole sentence — a fallback only) |
| Wrong pronunciation, but only for this one character | Same as above: rewrite as a homophone |

## Step 7: Assemble the final piece

```bash
./scripts/03_postprocess.sh -n my_first_voice -d audio/raw_run1_trim
```

Output lands in `audio/out/`: `my_first_voice.mp3` (192k, ready to send) plus `my_first_voice.wav` (24kHz master, keep it for further processing).

To add background music: `-b audio/bgm/your-bgm.mp3`. The BGM loops automatically and is sidechain-ducked by the voice — it gets out of the way when someone is speaking, rather than being hard-layered on top.

To change the pause between segments: `-g 0.5` (default is 0.35 seconds).

---

## Common pitfalls (every one of these was hit for real)

1. **Synthesis fails with "Kernel size can't be greater than actual input size"**: the actual cause is a script missing the `<|endofprompt|>` prefix, which stops the LLM from generating any speech tokens, so the vocoder receives empty data. `02_synthesize.py` includes the prefix already — don't drop it when editing the code.
2. **diffusers fails with `cannot import name 'cached_download'`**: diffusers 0.25 is incompatible with newer huggingface_hub. `deploy.sh` patches this automatically; if you fix it by hand, don't downgrade huggingface_hub — that breaks newer transformers.
3. **fastapi/gradio/tensorrt/deepspeed won't install**: you don't need them, inference never touches them. What's actually required is envwrap, hydra-core, lightning, rich, gdown, wget, librosa, soundfile, pyarrow, pyworld — `deploy.sh` fills those in.
4. **Every line opens with an "ah"**: see step 5 for the causes — a dirty reference-audio onset, or generation-side onset. Use the diagnostic column to tell which: re-cut the reference audio for the former, run the trimming script for the latter.
5. **`uv venv` hangs**: uv is downloading a Python interpreter from GitHub. The deploy script only uses an interpreter already on your machine; in other contexts set `UV_PYTHON_DOWNLOADS=never`.
6. **`third_party/Matcha-TTS` is empty**: `git clone --depth 1 https://github.com/shivammehta25/Matcha-TTS.git CosyVoice/third_party/Matcha-TTS`.
7. **The cloned voice bleeds into another speaker**: a second person got into the reference clip. Pick new material.
8. **`ModuleNotFoundError` partway through synthesis**: dependencies aren't fully installed. Re-run `./deploy.sh` to fill the gaps, or install whatever it reports as missing.

## Legal and ethical boundaries

Voice cloning engages the rights of the person being cloned. Cloning a film or TV performance for public release involves the rights around the character and the voice actor; cloning a real person's voice requires their consent. This repository provides a technical implementation only. Use it within the bounds of what you're authorized to do, and don't use the generated content to deceive or impersonate.

## Upstream sources

- Code: https://github.com/FunAudioLLM/CosyVoice
- Model: https://www.modelscope.cn/models/FunAudioLLM/Fun-CosyVoice3-0.5B-2512
- Paper: https://arxiv.org/pdf/2505.17589

## License

MIT
