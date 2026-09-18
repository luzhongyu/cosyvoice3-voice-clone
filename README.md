# cosyvoice3-voice-clone

本地跑的音色克隆流水线。用 CosyVoice 3 做零样本/跨语言克隆，输入一段参考音频 + 一份台本，输出成品音频。全程离线，不上传任何素材。

设计决策与踩坑记录见 **[DESIGN.md](DESIGN.md)**。

---

## 开始之前，你需要准备什么

| 需要准备 | 说明 |
|---|---|
| **想克隆的音色素材** | 一段包含目标说话人的音频/视频（电视剧、动画、播客、本人录音都行）。关键要求：**只有一个人说话、连续不间断、没有背景音乐盖过人声**。有 BGM 也行，后面有办法处理，但人声越干净效果越好 |
| **一台 Apple Silicon Mac** | M 系列芯片，16GB 内存起步（0.5B 模型，CPU 推理）。理论上 x86 + GPU 也可以，脚本未适配 |
| **约 2.5GB 磁盘空间** | 模型权重 2GB + 环境 |
| **会装 brew** | ffmpeg / uv 用 brew 装 |
| **约 30 分钟** | 首次部署 15 分钟（取决于网速），素材处理 10 分钟，第一次合成试听 5 分钟 |

成品效果预期：音色相似度"很像"，韵律自然度看运气（每句话是独立生成的，有抽卡成分，见第 6 步）。CPU 上合成 1 分钟音频约需 5~7 分钟，适合做几分钟以内的定制内容，不适合实时对话。

---

## 第 1 步：部署环境（约 15 分钟，只需一次）

```bash
git clone https://github.com/<you>/cosyvoice3-voice-clone.git
cd cosyvoice3-voice-clone
./deploy.sh
```

这一条命令会自动完成：装 ffmpeg/uv 检查 → 建 Python 虚拟环境 → 装 PyTorch 和全部依赖 → 克隆 CosyVoice 仓库和 Matcha-TTS 子模块 → 给 diffusers 打兼容补丁 → 下载 2GB 模型 → 冒烟验证。

结束时看到 `全链 import OK` 和 `模型就位` 就是成功了。中途某个包安装失败不用慌，脚本会单独列出失败项，大部分不影响推理，重跑 `./deploy.sh` 会跳过已完成的步骤。

只想要环境不想下模型：`./deploy.sh --skip-model`。装完想验证：`./deploy.sh --verify-only`。

## 第 2 步：准备参考音频（决定相似度上限的一步）

参考音频是整条流水线里最重要的输入。目标：从素材里切出 **3~10 秒**、单人连续说话、干净的片段。

```bash
# 2a. 把素材放进 audio/raw/，扫描哪些时间段有人在说话
./scripts/00_scan_speech.sh audio/raw/你的素材.mp4

# 2b. 素材带背景音乐的话，先分离人声（需要 demucs，脚本会提示安装）
./scripts/01_prep_reference.sh audio/raw/你的素材.mp4 -s 30 -d 8 --separate -n ref

#    没有配乐就直接切：从扫描报告挑的起点切 8 秒
./scripts/01_prep_reference.sh audio/raw/你的素材.mp4 -s 12.5 -d 8 -n ref
```

产物是 `audio/reference/ref.wav`（24kHz 单声道）。三个关键要求：

- **从语音起点开始裁**。起点前哪怕混进 0.2 秒的呼吸声，克隆出来的每句话开头都会带一声"啊"——这是实测踩过的坑
- 整段只有一个人，中途不被打断（混进第二个人，音色会串）
- 别超过 30 秒（代码里有硬断言），3~10 秒是甜点区

**要做 zero-shot（推荐），还需要这段音频的文字转写**。转写用 whisper：

```bash
.venv/bin/python -c "
import whisper
r = whisper.load_model('small').transcribe('audio/reference/ref.wav', language='zh')
print(r['text'])
"
```

转写完**逐字核对**：whisper 会把角色名、专有名词写错，也会把提示词幻觉进开头，这些都要手改。转写不准，zero-shot 的相似度优势就没了。

## 第 3 步：写台本

台本就是普通文本，**每行一个片段**，参照 `台本示例.txt`：

```
你好呀！我是你的专属通话员，今天也要元气满满哦。
睡前故事时间到了，快躺好，盖好小被子，闭上眼睛。
今天是星期六，天气很好，我们去公园放风筝吧。
```

规则：

- 想在哪里停顿就换行，片段之间会自动插 0.35 秒留白
- 不要写括号舞台说明（会念出来），语气靠标点控制
- 数字写中文（"三十秒"而不是"30秒"）
- 每行 10~40 字比较稳，太短的行（两三个字）节奏容易飘

## 第 4 步：合成

```bash
.venv/bin/python scripts/02_synthesize.py --script 台本示例.txt \
  --ref audio/reference/ref.wav \
  --prompt-text "参考音频里逐字说的那句话" \
  --out-dir audio/raw_run1
```

`--prompt-text` 给了就是 zero-shot 模式（推荐）；不给走 cross-lingual（不需要转写，相似度略低）。跑完每行一个 `seg_XX.wav` 在 `--out-dir` 里，外加一份 manifest.txt 记录每段的时长和文本。

CPU 上的速度预期：模型加载 15~30 秒，之后每 10 秒音频约 1 分钟。

## 第 5 步：切除句首杂音（必跑）

合成结果每段开头会有一声轻微的"啊"——这是模型固有的起音现象，不是你操作错了。用双规则检测切割：

```bash
.venv/bin/python scripts/10_trim_onset.py audio/raw_run1 audio/raw_run1_trim
```

输出目录里的片段就是干净的，后面只用这个目录。

## 第 6 步：逐句试听，抽卡换 take

这是质量把控的核心。**同一句话每次生成的音色和节奏都有波动**——不满意就多生成几条挑最好的，而不是调参数：

```bash
# 参考 examples/take_variants.py：同一句话抽 3 条
.venv/bin/python examples/take_variants.py
```

试听 `audio/takes_example/take_1~3.wav`，挑中哪条，就把它复制成片段目录里对应的 `seg_XX.wav`。

句子的具体毛病各有各的修法（都是改台本，不是调参数）：

| 毛病 | 修法 |
|---|---|
| 两个字黏在一起没有停顿 | 拆成两行，让片段间留白接管停顿 |
| 语速忽快忽慢 | 相邻的短句合并成一行；把"："改成"，"（冒号容易触发播报腔） |
| 某个字声调读错 | 改写成同音的常用字（最稳）；或拼音标注 `[d][uō]`（能锁读音但会影响整句节奏，兜底用） |
| 发音不对但只有这一个字 | 同上，同音字改写 |

## 第 7 步：拼装成品

```bash
./scripts/03_postprocess.sh -n my_first_voice -d audio/raw_run1_trim
```

产物在 `audio/out/`：`my_first_voice.mp3`（192k，直接能发）+ `my_first_voice.wav`（24kHz 母带，留着做二次加工）。

想加背景音乐：`-b audio/bgm/你的BGM.mp3`，BGM 会自动循环并被人声侧链压低（有人说话时 BGM 自动让路，不是硬叠）。

想改段间停顿：`-g 0.5`（默认 0.35 秒）。

---

## 常见坑（全部实测撞过）

1. **合成报 "Kernel size can't be greater than actual input size"**：真实原因是台本缺 `<|endofprompt|>` 前缀导致 LLM 不生成语音，声码器收到空数据。`02_synthesize.py` 已内置前缀，自己改代码时别漏。
2. **diffusers 报 `cannot import name 'cached_download'`**：diffusers 0.25 和新版 huggingface_hub 不兼容。`deploy.sh` 自动打补丁；手动修就别降级 huggingface_hub，会弄坏 transformers。
3. **装不上 fastapi/gradio/tensorrt/deepspeed**：不用装，推理用不到。真正需要的是 envwrap、hydra-core、lightning、rich、gdown、wget、librosa、soundfile、pyarrow、pyworld，`deploy.sh` 会补齐。
4. **每句开头有"啊"**：模型固有起音现象，第 5 步的切除脚本就是干这个的；如果切完还有，先检查参考音频起点是否干净。
5. **`uv venv` 卡死**：uv 在从 GitHub 下载 Python 解释器。部署脚本只用本机已有版本；其他场景设 `UV_PYTHON_DOWNLOADS=never`。
6. **`third_party/Matcha-TTS` 是空的**：`git clone --depth 1 https://github.com/shivammehta25/Matcha-TTS.git CosyVoice/third_party/Matcha-TTS`。
7. **克隆出来的声音串音**：参考片段混进了第二个人，重新挑素材。
8. **合成到一半 `ModuleNotFoundError`**：依赖没装全，重跑 `./deploy.sh` 会补齐；报缺什么装什么。

## 法律与道德边界

音色克隆涉及被克隆者的权利。克隆影视角色配音用于公开发布，涉及角色形象与配音演员的授权；克隆真人声音，须取得本人同意。本仓库只提供技术实现，请在获得授权的范围内使用，生成的内容不要用于欺骗或冒充。

## 上游出处

- 代码：https://github.com/FunAudioLLM/CosyVoice
- 模型：https://www.modelscope.cn/models/FunAudioLLM/Fun-CosyVoice3-0.5B-2512
- 论文：https://arxiv.org/pdf/2505.17589

## License

MIT
