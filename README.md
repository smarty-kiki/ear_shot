# 耳录 EarShot

> 开会不用记笔记。它替你听，**待办自己长出来**。

[![CI](https://github.com/smarty-kiki/ear_shot/actions/workflows/ci.yml/badge.svg)](https://github.com/smarty-kiki/ear_shot/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/smarty-kiki/ear_shot)](https://github.com/smarty-kiki/ear_shot/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple)

挂着它开会：**麦克风**里是你，**电脑里**是会议对方，两路一起听、在本机转成文字，几秒内把「谁、什么时候、要交什么」一条条贴在屏幕右边。开完会，待办已经在屏幕上排好了。

<p align="center">
  <img src="docs/panel-expanded.png" width="430" alt="耳录面板：四条待办，每条列清 待办/时间/地点/人物/输出物/说明 六项字段">
</p>

## 为什么是它

- **两路声音都听得见。** 麦克风（你）+ 系统声音（会议对方）分两路识别，「谁说的」不用猜 —— 白送的说话人标注：你说「我」揽下的活，和对方说的「你」，人物栏各归各。
- **识别全在本地。** 语音转文字走苹果原生框架（SpeechAnalyzer），**音频永远不出这台 Mac**，离线也能跑。不注册、不登录、不订阅。
- **准实时，不是事后总结。** 一句话说出口，几秒内待办就上了面板；后面聊到的补充（时间、地点、要交的东西）自动补进同一条，越聊越全。
- **序号是活的。** 每条待办有个稳定序号，屏幕上写着「待办 3」，会上照着念「**待办 3 的地点改成会议室 B**」—— 这条指令它听得懂，改的就是第 3 条。
- **不打扰。** 一个小把手贴在屏幕右边，红点慢闪 = 在听。点开看、再点收起，不抢焦点、不占 Dock，你原来干什么还干什么。
- **不落盘。** 待办和转写只存在内存里，退出即清空 —— 会议内容不会莫名其妙留在硬盘上。

## 增量补全长什么样

新听出来的字段**亮一下橙色**，被作废的字段划上红色删除线，整条不要了就整块变红 —— 模型的每次修订都是看得见的：

<p align="center">
  <img src="docs/incremental-update.png" width="430" alt="增量反馈：补全的字段橙色高亮，作废的字段红色删除线，删除的条目整块变红">
</p>

## 隐私，说清楚

- 语音识别 **100% 在本机**（苹果 Speech 框架），音频不出机器。
- 只有**最近约 1200 字的转写文本窗口**（大小可配）会发给你自己配置的 DeepSeek 接口，用来把口语变成结构化待办 —— 这是唯一离开这台机器的内容。接口地址和模型都可以换。
- API Key 只存在本机 `~/.config/ear_shot/config.json`，代码里没有任何上报、统计、遥测。
- 待办与转写**不留档**：关掉即清空，刻意如此。

## 安装

要求 **macOS 26 或更新**（识别用的是苹果 2025 年的新语音框架 SpeechAnalyzer）。

1. 从 [Releases](https://github.com/smarty-kiki/ear_shot/releases) 下载 `EarShot-<版本>.dmg`
2. 打开 DMG，把 **EarShot.app 拖进「应用程序」**
3. 本应用未做 Apple 公证，换台机器首次打开会被 Gatekeeper 拦一下：**右键点图标 → 打开 → 再点「打开」**，只需要一次
4. 校验下载完整性（可选）：`shasum -a 256 -c EarShot-<版本>.dmg.sha256`

**第一次用**：

1. 面板底栏「设置」里填一个 [DeepSeek](https://platform.deepseek.com) 的 API Key（自备；一次抽取只花几百个 token，日常开会用很便宜），点「测试连接」确认没问题
2. 点「开始监听」会要两道系统权限：
   - **屏幕录制**（必须）—— 采系统声音和麦克风都靠它。授权后**必须重启耳录才生效**，面板上的「去授权」按钮和菜单栏都有入口
   - **麦克风**（可选）—— 不授权也能跑，只是听不见「我」，降级成只听系统声音
3. 说一句含待办的话（「下周五之前把季度复盘的 PPT 发给老王」），几秒内待办就会出现在面板里

## 界面怎么用

面板贴在屏幕右侧，是个带反角的「把手」，**点击**展开（不是悬停）。收着的时候长这样 —— 红点慢闪是在听，橙色数字是没看过的新改动：

<p align="center">
  <img src="docs/collapsed-unread.png" width="120" alt="收起态把手：红点表示正在监听，橙色角标 2 表示两条未读">
</p>

| 点什么 | 干什么 |
|---|---|
| 收起态的把手 | 展开面板 |
| 面板里的待办行 | 复制该条（六字段多行文本，空字段省略） |
| 面板底栏按钮 | 开始/停止监听、清空、复制全部、设置、退出 |
| 菜单栏（耳朵图标）→「设置…」⌘, 或底栏齿轮 | 打开设置窗口 |
| 面板其他区域（标题栏、空白） | 收起 |

- 监听中：把手圆点**红色慢闪**，标题栏计时；停止后变灰。
- 标题栏「耳录」后面有**两条声纹**：麦克风图标那条是「我」（麦克风），喇叭图标那条是电脑里的声音（会议对方）—— 扫一眼就知道哪路在收、现在有没有动静，不用盯转写文字。没在监听时两条都压暗躺平。
- 声纹再往右是**大脑图标 + 一个数字**：这次打开以来大模型回包累计消耗的 token，每成功回一次包就涨（失败自动重试的不算）；悬停能看到不缩写的精确值。没消耗过时是暗的。点「清空」不清它，重启才归零。
- 有新待办**或某条被补全/修改**（「待办 1 的地点改成会议室 B」也算）：角标数字 + 把手**外框亮色脉冲**，展开看过即已读。收着的时候只有**新建**条目会响一声提示音（Bottle，可关）——补全不响，抽取几秒一轮，每轮都叮会变连珠炮。
- 鼠标移到把手左侧那圈光晕留白上点击 → 穿透给下面的 app，不被耳录吞掉。

## 设置窗口

面板底栏的**设置**（齿轮）或菜单栏**设置…**（⌘,）打开 —— 常用项都在这里，不用再手改 JSON：

- **DeepSeek**：API Key（眼睛图标可看一眼）、模型、接口地址，外加**测试连接** —— 拿当前填的内容（没保存的草稿也算）打一次最小请求验 key 和地址，401 会直接说「API Key 无效」。
- **提醒与采集**：声音提醒、麦克风、系统声音三个开关。
- **高级**：「我是谁」、识别语言、抽取静默、最小间隔、兜底滞后、窗口字数，每项带一句说明；不折叠，打开就是全的。
- **「我是谁」**：填上你的名字后，待办的人物栏不再出现「我」—— 麦克风那路（你）说「我」揽下的活、对方对着你说「你」，人物栏都落成这个名字。电脑声音那路的「我」是对方**自己**，不会被安上你的名字（两路的「我」不是一个「我」，提示词里专门分）。留空 = 没配，人物栏继续记「我」。
- **草稿语义**：打开时从磁盘鲜读；改动点「保存」才写回并生效，取消 / Esc / 直接关窗都是丢弃草稿。填了但填错的（比如地址不是网址、秒数是负数）会拦住保存并说明原因；留空的模型 / 地址 / 语言回落默认值。

窗口里能正常打字、⌘V 粘 key（accessory 应用平时没有菜单栏，打开设置窗口时会临时装一条隐藏主菜单来接这些键位）。`thinking` 刻意不在界面上：关掉思考是「准实时」成立的前提，它是配置而不是一个选项。

## 配置

`~/.config/ear_shot/config.json`（首次启动自动生成模板）是配置的**底座**。日常改配置走上面的设置窗口；菜单栏里「打开配置文件」「重新加载配置」保留为逃生舱 —— 手工改完（比如动 `thinking`）点「重新加载配置」即生效（影响下一轮抽取和下次开听）。

| 字段 | 默认 | 说明 |
|---|---|---|
| `apiKey` | `""` | DeepSeek key，**必填**（只认这一处，不从环境变量兜底）；空着抽取会停住并在面板上提示 |
| `baseURL` | `https://api.deepseek.com` | 接口地址 |
| `model` | `deepseek-flash` | 模型名 |
| `thinking` | `disabled` | 必须关思考，否则一句话要烧几百个 reasoning token，准实时就没了 |
| `locale` | `zh-CN` | 识别语言 |
| `myName` | `""` | 「我」在人物栏里落成的名字（空 = 没配，记「我」）；电脑声音那路的「我」不受影响 |
| `captureMic` / `captureSystem` | `true` | 两路声音分别开关 |
| `windowChars` | `1200` | 每次送给模型的最近转写字数 |
| `debounceSeconds` | `2.0` | 弱断句（逗号/省略号收尾）等这么久就发；句号/问号/叹号收尾的直接发 |
| `minIntervalSeconds` | `2.0` | 两次抽取的最小间隔，话说得再密也打不爆 API（也把连发定稿合并成一轮） |
| `maxStalenessSeconds` | `5.0` | 没有标点的长句等这么久发；同时是「拖着没抽」的上限 |
| `notifySound` | `true` | 新待办提示音 |

没配 key / API 报错时面板上直接显示原因和对应按钮，不静默失败。

## 常见问题

**收费吗？** app 本身开源免费（[MIT](LICENSE)）。抽待办需要你自己在 [DeepSeek](https://platform.deepseek.com) 开个 API Key —— 一次抽取只花几百个 token，日常开会用很便宜。

**会上说的话会被上传吗？** 音频不会。只有最近约 1200 字的**转写文本**会发给你自己配置的 DeepSeek 接口用来抽待办，详见「[隐私，说清楚](#隐私说清楚)」。

**跟云端会议助手（妙记/听悟那类）有什么不一样？** 不用上传音频、不用注册、不用订阅、没有时长和场次限制，也不用在录音前征求整个会议室同意（音频根本没离开你的电脑）。代价：待办抽取要自备一个 DeepSeek key。

**支持英文/其他语言吗？** 支持。设置里换「识别语言」即可，首次用新语言会自动下载对应语音模型。

**为什么要求 macOS 26+？** 用的是苹果新一代语音框架 SpeechAnalyzer，识别质量和实时性比老框架好一截，代价是系统版本门槛高。

**数据存在哪？** 内存里。退出即清空 —— 这是刻意设计，见「已知限制」。

## 从源码构建

```bash
make build          # 构建到 dist/EarShot.app
make run            # 构建并启动
make test           # 离线自检全套（不需要权限、不需要 key）
make dmg            # 打包发布 DMG 到 release/
```

首次运行的两道权限见上面「[安装](#安装)」。开发提示：ad-hoc 签名每次重新构建都会变，屏幕录制授权可能因此失效、需要重新授权。把产物固定放在 `~/Applications` 或 `/Applications` 再授权，能显著减少反复弹窗；彻底点的办法：用固定签名身份构建（`CODESIGN_IDENTITY="<证书名>" ./build.sh`，自签证书就行）—— 授权认身份不认哈希，重建就不用重来。

分支约定、提交前自检、红线都在 [CONTRIBUTING.md](CONTRIBUTING.md)；打包发布走 `release.sh`（`make publish` 一键发 GitHub Release）。

## 自检命令

不需要 GUI 和权限，全部可以离线跑（`./build/EarShot` 或 `./dist/EarShot.app/Contents/MacOS/EarShot`）：

| 命令 | 验什么 |
|---|---|
| `--extract <文件> [--today 2026-10-10] [--myName 王小明]` | **抽取链路**：文件按 `==` 分轮，每轮一次真实 API 调用；断言语法见 `Sources/Extractor.swift`。提示词和合并逻辑改动的第一道关。开头的离线断言（token 解码、碎片护栏、时间槽、相对日期、未读计数）不联网也跑。不给 `--myName` = 按「没配名字」跑（不借真配置里的名字，断言才是死的）；配了名字的路径见 `testdata/sample-myname.txt` |
| `--senttest` | **断句分级**：刚性/弱/无标点的判定与等待时钟（用例取自实测日志原话） |
| `--transcribe <音频> [--verbose]` | **识别链路**：拿音频文件跑真识别（首次会下载中文模型） |
| `--pcmtest` | **PCM 转换**：合成 SCK 形状的音频帧走一遍 CMSampleBuffer → AVAudioPCMBuffer，逐字节核对。不用权限 |
| `--echotest` | **回声过滤**：不用耳机时同一句会在两路各识别一份，判定用例取自真实运行日志原话 |
| `--wavetest` | **声纹电平**：合成音频算电平（静音 / 满幅 / 正弦 / Int16 与 Float 对照）+ 快起慢落与历史保留 |
| `--settingstest [--render 目录]` | **设置窗口**：草稿→配置映射、校验拦截、编解码往返（绝不碰真配置）；`--render` 离屏按窗口真实高度出设置表单的 PNG，并量表单内容高度把关「打开就是全的」 |
| `--capture [秒数] [--verbose]` | **采集联跑**：采集 + 识别一起；没授权只报状态，不弹窗 |
| `--preview [目录]` | 离屏渲染各形态界面图（收起三态 / 展开 / 空 / 故障 / 变化反馈 / 滚动 / 动画关键帧）—— README 里的图就是它直出的 |
| `--animframes [目录]` | 逐帧渲染生长动画 |
| `--states` | 状态 → 配色映射表（把手圆点、角标、外框） |
| `--hittest <x> <y> [行数] [滚动] [--problem]` | 点击命中映射自检（点击是这个工具唯一的手势） |
| `--dump` | 打印当前待办列表和复制用的文本 |
| `--seed N` | 塞 N 条假待办后正常启动 —— 不碰音频就能在真窗口里验滚动/点击 |

## 架构

```
SCStream（.audio=对方 + .microphone=我，两路分开 = 白送说话人标注）
  └→ AudioCapture ── 重采样 ──→ Transcriber ×2（SpeechAnalyzer，每路一个）
  │     └→ TranscriptLog（只留定稿段）── 定稿窗口 ──→ Extractor（DeepSeek）
  │                                                   ├→ TodoStore（合并/去重/序号）→ 面板
  │                                                   └→ 回包 usage 累计 → 标题栏「大脑 + token」
  └→ AudioMeters（顺手算电平，20Hz）→ 标题栏两条声纹（我 / 对方）
```

- `Sources/Listener.swift` 是总控：权限、模型下载、抽取节奏、故障提示都收在里面，界面只读 store 上的字段。
- 抽取节奏按**断句分级**：句号/问号/叹号收尾（刚性）直接发；逗号/省略号收尾（弱）等 `debounceSeconds`；没标点等 `maxStalenessSeconds`；任何新定稿把等待时钟清零重记。三者之外还有最小间隔兜底；失败会自动重试（revision 只在成功时前进）。
- 停止监听会先停采集再停识别器，收工前补抽一次（退出 app 时跳过，不拖慢退出）。
- 脚本：`build.sh` 构建、`run.sh` 构建并启动、`release.sh` 打包 DMG（`make publish` 发 GitHub Release）；分支与发布流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 目录结构

```
Sources/
  main.swift         入口 + 全部自检命令
  App.swift          AppDelegate + 控制器（窗口/点击/光晕/菜单栏）
  ShotUI.swift       几何与视图（DockShape / 面板 / 待办行）
  Listener.swift     听→转写→抽取→落面板 的总控
  AudioCapture.swift ScreenCaptureKit 两路采集
  AudioMeters.swift  两路电平 → 标题栏声纹（+ --wavetest 自检）
  Transcriber.swift  SpeechAnalyzer 流水线
  TranscriptLog.swift 转写缓冲
  Extractor.swift    DeepSeek 抽取 + --extract 自检
  TodoStore.swift    待办仓库（合并/去重/未读/序号/token 累计，纯内存）
  Models.swift       TodoItem / 字段
  Config.swift       ~/.config/ear_shot/config.json
  Settings.swift     设置窗口（草稿表单 + 测试连接 + 自检）
  Preview.swift      离屏渲染
  SoundPlayer.swift  提示音
```

## 已知限制

- **不用耳机时，对方的声音会在两路各出一次**：喇叭外放的声音会被麦克风再从空气里听一遍，于是「对方」和「我」各识别出一份几乎相同的文本。两路文本高度相似时，后到的那份会被当回声丢掉（判定用例见 `--echotest`）。戴耳机可以从源头避免这种重影。
- **退出即清空**，没有二次确认、没有导出（按需求刻意不落盘）。误关一场会的记录就没了。
- 待办行的字段是逐字显示的，很长的句子在行内会截断，复制的文本是全的。
- 换语言要改 `locale`（首次用新语言会再下载一次模型）。

## 参与贡献

欢迎 PR。分支约定、提交前自检、红线都在 [CONTRIBUTING.md](CONTRIBUTING.md)。有想法或遇到问题，开个 [Issue](https://github.com/smarty-kiki/ear_shot/issues)。

如果耳录帮到了你，给个 ⭐ 就是最大的支持。

## License

[MIT](LICENSE)
