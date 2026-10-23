# 响一下 · TapSound

一个轻量、离线、无第三方依赖的 iOS 音效板。点一张卡片，就播放对应的声音。

![App 预览](preview/app-preview.png)

> 上图是按实际 SwiftUI 样式制作的设计预览；当前开发机为 Windows，尚未在 Xcode 模拟器中截图。

## 快速开始

环境：**iOS 17.0+**、**Xcode 15.0+**、Swift 5。

1. 在 macOS 上双击打开 `TapSound.xcodeproj`。
2. 选择 `TapSound` scheme 和任意 iPhone 模拟器。
3. 按 `⌘R` 运行。

直接在真机运行前，需要在 Xcode 的 **Signing & Capabilities** 里选择自己的 Team。当前 Bundle ID 是 `com.example.tapsound`，建议同时改成你自己的唯一标识。

想在 Windows 上先听一遍？直接播放 [`preview/all-sounds-demo.wav`](preview/all-sounds-demo.wav)，会按顺序播放全部 12 个音效（约 14 秒）。

## 功能

- **12 个内置音效**：啵、叮、金币、激光、弹簧、鼓点、风过、快门、气泡、成功、错误、魔法。
- **点击即响**：短按卡片立即播放，触感反馈；同一张卡片重复点击会从头重播。
- **可叠加**：先点「魔法」，再点「鼓点」，两个声音会自然叠在一起。
- **批量静音**：右上角喇叭按钮一键静音，卡片同步变暗。
- **实时状态栏**：显示正在播放 / 刚刚播放的声音，并带动态均衡器。
- **深色视觉**：强制深色，配合渐变卡片；iPad 上自动居中。
- **无障碍**：VoiceOver 标签、动态字体单列布局、减少动态效果支持。
- **完全离线**：不联网、不申请权限、不收集数据。

所有音效与图标都由仓库里的 Python 脚本合成，不含第三方采样。

## 工程结构

```text
TapSound/
├── TapSound.xcodeproj/          # 打开这个
├── TapSound/
│   ├── TapSoundApp.swift       # @main 入口
│   ├── SoundBoardView.swift    # 主界面、状态栏、背景
│   ├── SoundCardView.swift     # 单张音效卡片及按压样式
│   ├── SoundEngine.swift       # AVAudioSession / AVAudioPlayer
│   ├── SoundEffect.swift       # 12 个音效的配置表
│   ├── Color+Hex.swift
│   ├── Assets.xcassets/        # AppIcon、AccentColor
│   └── Sounds/                 # 12 个 44.1kHz / 16-bit / 单声道 WAV
├── scripts/
│   ├── generate_sounds.py      # 合成全部音效
│   ├── generate_icon.py        # 生成 AppIcon
│   ├── generate_xcodeproj.py   # 重建 .xcodeproj / scheme
│   ├── make_demo.py            # 拼接桌面试听音频
│   ├── inspect_audio.py        # 查看音频格式与电平
│   └── validate_project.py     # 工程、资源、代码静态检查
├── preview/
│   ├── app-preview.png         # 界面设计预览
│   └── all-sounds-demo.wav     # 12 个音效试听
└── README.md
```

## 音效表

| 卡片 | 英文 | 时长 | 声音设计 |
| --- | --- | ---: | --- |
| 啵 | POP | 0.20s | 快速下滑的正弦波 + 短噪声瞬态 |
| 叮 | BELL | 1.15s | 六个非谐波分音，长衰减 |
| 金币 | COIN | 0.46s | B5 → E6 两段明亮方波 |
| 激光 | LASER | 0.52s | 锯齿波高频下滑 + 短回声 |
| 弹簧 | BOING | 0.88s | 低频弹簧音高摆动 |
| 鼓点 | DRUM | 0.52s | 音高下坠的底鼓 + 噪声敲击 |
| 风过 | WHOOSH | 0.78s | 噪声的带通扫频与包络 |
| 快门 | SHUTTER | 0.24s | 两段机械噪声瞬态 |
| 气泡 | BUBBLE | 0.62s | 五颗上滑气泡音 |
| 成功 | SUCCESS | 1.25s | C–E–G–C 琶音 + 高音闪光 |
| 错误 | ERROR | 0.62s | 两记下行的低频 buzz |
| 魔法 | MAGIC | 1.40s | 高音琶音 + 噪声闪光 + 回声 |

## 常用自定义

### 改文案、颜色、图标

编辑 `TapSound/SoundEffect.swift` 里的 `SoundEffect.all`：

```swift
SoundEffect(
    id: "pop",                    // 保持唯一
    title: "啵",
    englishTitle: "POP",
    hint: "短促的泡泡破裂声",
    symbolName: "drop.fill",     // 任意 SF Symbol
    resourceName: "pop",         // 对应 Sounds/pop.wav
    colors: [Color(hex: 0x22D3EE), Color(hex: 0x2563EB)]
)
```

`symbolName` 必须换成真实存在的 SF Symbol 名称。

### 换音效

把 WAV 放进 `TapSound/Sounds/`，注意：

1. 文件名要和 `resourceName` 一致；
2. 推荐 44.1kHz、16-bit、单声道；
3. 把新文件加进 `scripts/generate_xcodeproj.py` 的 `SOUNDS` 列表，然后重新生成工程：

```bash
python scripts/generate_xcodeproj.py
```

也可以直接在 Xcode 里拖入文件并勾选 TapSound target。注意重新运行生成脚本会覆盖手动改动。

### 静音键行为

`SoundEngine.swift` 使用：

```swift
try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
```

- `.playback`：手机打开静音拨片时仍然出声。
- `.mixWithOthers`：不打断用户正在播放的音乐。

如果想尊重 iOS 静音拨片，把 `.playback` 改成 `.ambient`。如果希望播放音效时暂停其他 App 的音乐，移除 `options: [.mixWithOthers]`。

### 重新生成素材

```bash
python -m pip install numpy pillow
python scripts/generate_sounds.py
python scripts/generate_icon.py
python scripts/make_demo.py
```

## 校验

Windows 上也能运行的静态检查：

```bash
python -m pip install numpy pillow
python scripts/validate_project.py
```

会检查 pbxproj 的 OpenStep 结构、文件引用、scheme、12 个音效与 `SoundEffect.all` 的对应关系、WAV 格式、图标尺寸，以及若干 Swift 代码不变量。

**尚未完成的验证：** 当前环境没有 Xcode / iOS SDK，无法执行真实编译、模拟器运行和真机听感验收。工程按 Xcode 15 及以上版本的标准结构生成；如果 Xcode 提示迁移 project format，允许即可。

## 许可

代码与合成音频均以 MIT License 发布，可自由修改和商用，无需署名。
