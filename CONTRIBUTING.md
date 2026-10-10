# 参与开发

耳录是个 macOS 常驻小工具：持续听会议（系统声音 + 麦克风）→ 苹果本地语音识别 → DeepSeek 抽出待办 → 贴屏幕右侧的面板。欢迎提 issue 和 PR。

## 环境

- macOS 26+（`SpeechAnalyzer` 是 macOS 26 的 API，编译目标也是 26.0）
- Xcode 26+（或提供 26+ SDK 的 Command Line Tools）；纯 `swiftc` 直编，没有 Xcode 工程
- 编辑器里 SourceKit 对单文件报的「Cannot find type X」是跨文件噪音，忽略；编译权威是 `./build.sh`

## 分支与 PR

`main` 是保护分支，改动走「分支 → PR → CI 绿 → 合并」：

- 分支名：`feat/…`、`fix/…`、`docs/…`、`refactor/…`
- 一个 PR 一件事；PR 模板里有自检清单
- CI（`macos-26` runner）跑构建 + 离线自检全套，见 `.github/workflows/ci.yml`

## 提交前自检

```bash
make test     # 构建 + 离线自检全套，不需要权限、不需要 key（与 CI 同一套）
```

改了抽取或提示词（`Sources/Extractor.swift`），跑完整电池（需要本机配好 key）：

```bash
./build/EarShot --extract testdata/sample-meeting.txt --today 2026-10-10
./build/EarShot --extract testdata/sample-myname.txt  --today 2026-10-10 --myName 王小明
```

`--today` 必须钉死：断言是围着这个日期写的（「今天买明天的票」这类相对日期用例）。

## 红线

- **key 不入库**：API key 只放 `~/.config/ear_shot/config.json`，代码里不从环境变量兜底
- **不落盘**：待办和转写只存内存；想做持久化先开 issue 讨论
- **音频不出机器**：识别走苹果本地框架，只有抽出来的文本会发给 DeepSeek
- 自检断言里不读用户真配置（日期用 `--today` 钉、名字用 `--myName` 传）

## 本机开发：屏幕录制授权会跟着重建丢

ad-hoc 签名每次重建 CDHash 都变，而屏幕录制授权绑签名 —— **每重建一次就得重新授权一次**。两个缓解：

- 用固定签名身份构建：`CODESIGN_IDENTITY="<钥匙串里的签名证书名>" ./build.sh`（自签证书也行），授权认身份、重建不丢
- 日常使用从 DMG 安装到 `/Applications`，产物路径固定，授权更稳

## 发布

```bash
# 1. 升版本：改 VERSION 走 PR 合并（semver）
# 2. 打包 + 发布：
make publish        # = ./release.sh --publish
```

`release.sh` 干的事：构建（隔离到 `release/stage/`，**不碰 dist/**）→ 组装 DMG 内容（EarShot.app + /Applications 软链 + 安装说明）→ `hdiutil` 打包并校验 → 出 `release/EarShot-<版本>.dmg` 和 `.sha256`。加 `--publish` 再：打 tag `v<版本>` → `gh release create` 上传产物。

发布前置检查由脚本把守：工作树干净、在 main 上、与 origin/main 一致、tag 不重名。`gh` 需已登录。

**签名现状：ad-hoc，未公证。** 别的机器上下载打开会被 Gatekeeper 拦一次（右键 → 打开）。之后若拿到 Apple Developer ID，在 `build.sh` 的签名段接上 `codesign` + `notarytool` 即可（`CODESIGN_IDENTITY` 的口子已经留好）。
