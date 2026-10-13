import AVFoundation
import Foundation

/// 「听 → 转写 → 抽待办 → 落到面板上」这一整条链的总控。
///
/// 权限、模型下载、抽取节奏、失败提示都收在这里，界面只管读 `store` 上的
/// `listening / statusText / problem` 三个字段 —— 界面不知道
/// 底下是 Core Audio tap 还是别的什么。两路声音的动静（标题栏那两条声纹）
/// 单独走 `meters`，不混进 store：它不是「待办仓库」的东西。
///
/// 抽取节奏（断句分级 + 两道闸，和 Config 里那三个数一一对应）：
///  - **按断句分级**（见 `SentenceGate`）：最后一条定稿收在句号/问号/叹号上
///    （刚性）→ 直接发，不等；收在逗号/省略号上（弱）→ 等 `debounceSeconds`
///    静默；没有标点 → 等 `maxStalenessSeconds`。等待时钟从最后一条定稿起算，
///    任何新定稿都清零重记 —— 弱断句等来一句刚性断句，就按刚性直接走
///  - **硬下限**：两次之间至少隔 `minIntervalSeconds`，话说得再密也打不爆 API ——
///    顺带把「识别器把一句话拆成好几条定稿」这种连发合并成一轮。
///    抽取循环是串行的（一次请求在飞时不会发第二次），下限管的是节奏，不是并发
///  - **兜底**：`maxStalenessSeconds` 同时也是「拖着没抽」的上限 ——
///    有没抽过的文本拖过这么久就强行抽一次，没有它，一段没有标点的长发言
///    期间面板会是空的
@MainActor
final class Listener {

    private let store: TodoStore
    private let meters: AudioMeters
    private var config: Config

    private var capture: AudioCapture?
    private var mic: Transcriber?
    private var sys: Transcriber?

    /// 转写缓冲。停止监听就换一条新的 —— 上一场会的文本不该掺进下一场
    private var log = TranscriptLog()

    private var loop: Task<Void, Never>?
    private var clock: Timer?

    private var listeningSince: Date?
    private var lastFinalAt = Date.distantPast
    /// 有没抽过的文本从什么时候开始攒的
    private var pendingSince: Date?
    private var lastRunAt = Date.distantPast
    /// 已经送出去抽过的定稿数（转写缓冲每定稿一段就加一）
    private var lastExtractedRevision = 0

    private(set) var listening = false
    private var starting = false
    private var downloading = false

    /// 每次 start/stop 都 +1，`start()` 在每个 await 之后核对一遍。
    ///
    /// 起监听是要等好一会儿的（头一回开听要下几百 MB 的语音模型），
    /// 这期间用户完全可能再点一下「停止」。没有这个号，那个还在途中的
    /// `start()` 醒来之后会接着往下走 —— 明明按了停，监听还是起来了。
    private var generation = 0

    init(store: TodoStore, meters: AudioMeters, config: Config) {
        self.store = store
        self.meters = meters
        self.config = config
    }

    // MARK: - 开关

    /// 底栏按钮和菜单栏都走这儿（同步入口，实际动作丢到后台 Task）
    func toggle() {
        if listening || starting {
            Task { await stop() }
        } else {
            Task { await start() }
        }
    }

    func start() async {
        guard !listening, !starting else { return }
        starting = true
        generation += 1
        let gen = generation
        defer { starting = false }

        store.problem = nil
        store.problemAction = nil
        store.statusIsWarning = false

        // 1. 没配 API Key 就没必要听了 —— 听完也变不成待办，不如现在就说清楚
        guard !config.resolvedAPIKey.isEmpty else {
            store.problem = Extractor.Failure.noAPIKey.errorDescription
            store.problemAction = .openSettings
            store.statusText = ""
            return
        }

        // 2. 麦克风：没有也能跑，只是听不见「我」—— 降级成单路。
        //    （系统声音这边没有预检接口：权限在第一次建 tap 时才弹窗；没给的
        //    话采集那边 8 秒就能认出来，再由 systemAudioState 提示 —— 这里不拦）
        let micOK = await AudioCapture.requestMic()
        guard gen == generation else { return }        // 等授权的工夫里被按了停止
        if !micOK {
            AppDebug.log("[listen] 麦克风没授权，只收系统声音")
        }

        // 4. 起两路识别器（模型没装的话这一步会先下载，界面上有进度）。
        //    起的都是局部量，全须全尾地起完、并再核对一遍没有被停止，
        //    才提交给 self —— 中途作废时也只回滚自己起的这两个
        downloading = true
        defer { downloading = false }
        var startedMic: Transcriber?
        var startedSys: Transcriber?
        do {
            let locale = Locale(identifier: config.locale)
            if micOK {
                startedMic = try await Transcriber.start(speaker: .me, locale: locale) { [weak self] ev in
                    await self?.ingest(.me, ev)
                }
            }
            guard gen == generation else { await startedMic?.stop(); return }
            startedSys = try await Transcriber.start(speaker: .other, locale: locale, onDownloadProgress: { [weak self] p in
                Task { @MainActor in self?.showDownload(p) }
            }) { [weak self] ev in
                await self?.ingest(.other, ev)
            }
        } catch {
            await startedMic?.stop()
            if gen == generation { store.problem = "语音识别起不来：\(error)" }
            return
        }
        guard gen == generation else {
            await startedMic?.stop()
            await startedSys?.stop()
            return
        }

        // 5. 起采集。注意把两路识别器复制成局部量再进闭包 ——
        //    闭包在采集队列上跑，不能碰主线程上的属性
        let micT = startedMic
        let sysT = startedSys
        let meters = self.meters
        let micThrottle = LevelThrottle()
        let sysThrottle = LevelThrottle()
        let cap = AudioCapture(onBuffer: { speaker, buffer in
            // 喂识别器是主活；顺手给标题栏的声纹算个电平。
            // 电平就在采集队列上算（`level(of:)` 是纯函数、很便宜），
            // 但节流到 20Hz 才跳主线程 push —— 不节流的话一秒几十上百次
            // SwiftUI 更新，白烧 CPU
            switch speaker {
            case .me:
                micT?.feed(buffer)
                if micThrottle.shouldFire() {
                    let level = AudioMeters.level(of: buffer)
                    DispatchQueue.main.async { meters.push(level, speaker: .me) }
                }
            case .other:
                sysT?.feed(buffer)
                if sysThrottle.shouldFire() {
                    let level = AudioMeters.level(of: buffer)
                    DispatchQueue.main.async { meters.push(level, speaker: .other) }
                }
            }
        }, onInterrupted: { [weak self] err in
            Task { @MainActor in self?.interrupted(err) }
        }, onSystemAudioState: { [weak self] alive in
            Task { @MainActor in self?.systemAudioState(alive) }
        })
        do {
            try await cap.start(captureSystem: config.captureSystem, captureMic: micOK && config.captureMic)
        } catch {
            await cap.stop()
            await startedMic?.stop()
            await startedSys?.stop()
            if gen == generation { store.problem = "\(error)" }
            return
        }
        guard gen == generation else {
            await cap.stop()
            await startedMic?.stop()
            await startedSys?.stop()
            return
        }

        // 6. 全部就绪，一次性提交（从这里到 listening = true 之间不能再有 await，
        //    主线程上中间没有挂起点，stop() 就插不进来了）
        mic = startedMic
        sys = startedSys
        capture = cap
        listening = true
        store.listening = true
        store.statusIsWarning = false
        listeningSince = Date()
        log = TranscriptLog()
        meters.reset()              // 上一场留在声纹上的波形不能带进这一场
        lastExtractedRevision = 0
        pendingSince = nil
        lastRunAt = .distantPast
        lastFinalAt = .distantPast
        downloading = false         // 进度文字让位给计时（defer 里还会再置一次，无害）
        updateClockText()
        startClock()
        runExtractLoop()
        AppDebug.log("[listen] 开始监听（麦克风 \(micOK ? "✓" : "✗")，系统 \(config.captureSystem ? "✓" : "✗")）")
    }

    /// - Parameter finalExtract: 收工前把还没抽的文本补抽一次否。
    ///   点「停止监听」时要（停下来的那一刻最想看到的就是「刚才说的都记下了」）；
    ///   退出 app 时不要 —— 抽出来也没人看得到，白白拖慢退出
    func stop(finalExtract: Bool = true) async {
        guard listening || starting else { return }
        generation += 1      // 还在途中的那次 start() 就此作废
        listening = false
        starting = false
        store.listening = false
        clock?.invalidate()
        clock = nil
        loop?.cancel()
        loop = nil

        await teardown()

        if finalExtract { await extract(force: true) }
        store.statusText = ""
        meters.reset()
        AppDebug.log("[listen] 已停止（清单留着 \(store.todos.count) 条）")
    }

    /// 重新读配置：只影响下一轮抽取和下次开听
    func reload(config new: Config) {
        config = new
    }

    private func teardown() async {
        await capture?.stop()
        capture = nil
        await mic?.stop()
        mic = nil
        await sys?.stop()
        sys = nil
    }

    // MARK: - 识别结果进门（识别器在别的线程上，这里已经跳回主线程）

    private func ingest(_ speaker: Speaker, _ ev: TranscribeEvent) {
        switch ev {
        case .volatile:
            // 未定稿结果不进缓冲、也不上界面。面板中间那行实时文字已经拿掉，
            // 「有没有听到动静」由标题栏两条声纹表达（AudioMeters 那条路）；
            // 半截句子不参与抽取则是老规矩 —— 定稿才进门
            break
        case .final(let t):
            // 回声：不用耳机时喇叭的声音会被麦克风再听一遍，同一句在两路各定稿
            // 一份，谁先谁后不固定 —— 所以「谁后到丢谁」，先到的那份留着。
            // 只丢这一份文本，抽待办不受影响：前一份已经在窗口里了
            let other: Speaker = speaker == .me ? .other : .me
            if let prev = log.mostRecentFinal(from: other, within: EchoGuard.window),
               EchoGuard.looksLikeEcho(prev.text, t) {
                AppDebug.log("[listen] 回声过滤：[\(speaker.label)] 与刚才 [\(other.label)] 的定稿重复，丢掉这份：\(t.prefix(24))…")
                return
            }
            guard log.finalize(speaker, text: t) else { return }
            lastFinalAt = Date()
            if pendingSince == nil { pendingSince = Date() }
            AppDebug.log("[listen] 定稿 \(speaker.label)：\(t.prefix(40))\(t.count > 40 ? "…" : "")")
        }
    }

    // MARK: - 抽取节奏

    private func runExtractLoop() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self else { return }
                await self.extract(force: false)
            }
        }
    }

    /// - Parameter force: 收尾用。忽略 debounce 和下限，有没抽过的就抽
    private func extract(force: Bool) async {
        guard listening || force else { return }
        let rev = log.finalizedCount
        guard rev != lastExtractedRevision else { return }

        if !force {
            let now = Date()
            // 断句分级：刚性（句号/问号/叹号收尾）不等，直接发；弱（逗号/省略号）
            // 等 debounce；无标点等到兜底上限。任何新定稿都把 lastFinalAt 顶新
            // = 等待时钟清零重记，弱断句等来刚性断句就按刚性走
            let wait = SentenceGate.wait(forNewest: log.newestText,
                                         commaWait: config.debounceSeconds,
                                         plainWait: config.maxStalenessSeconds)
            let quiet = now.timeIntervalSince(lastFinalAt) >= wait
            let stale = pendingSince.map { now.timeIntervalSince($0) >= config.maxStalenessSeconds } ?? false
            guard quiet || stale else { return }
            guard now.timeIntervalSince(lastRunAt) >= config.minIntervalSeconds else { return }
        }

        let window = log.recentWindow(chars: config.windowChars)
        guard !window.isEmpty else { return }

        lastRunAt = Date()
        if force { pendingSince = nil }
        do {
            let out = try await Extractor.extract(window: window,
                                                  existing: store.todos,
                                                  config: config)
            let items = out.items
            // 回包成功才算消耗 —— 标题栏那个数字跟着涨（失败重试不涨）
            store.addTokens(out.tokens)
            lastExtractedRevision = rev
            pendingSince = nil
            if let err = store.statusIsWarning ? store.statusText : nil {
                // 上一轮的报错还挂着而这一轮通了 → 把红字收掉
                AppDebug.log("[listen] 抽取恢复正常（上一轮：\(err)）")
            }
            store.statusIsWarning = false
            updateClockText()          // 把可能挂着的报错行换回计时
            if !items.isEmpty { store.apply(items) }
        } catch {
            // 网络抖动是常事，下一轮会再试（有 minInterval 兜着，不会打爆）；
            // 别把整块面板打成「干不了了」
            store.statusText = "抽取失败，会自动重试"
            store.statusIsWarning = true
            AppDebug.log("[listen] 抽取失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 状态文字

    private func startClock() {
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateClockText() }
        }
    }

    private func updateClockText() {
        guard listening, let since = listeningSince, !downloading, !store.statusIsWarning else { return }
        let s = Int(Date().timeIntervalSince(since))
        store.statusText = String(format: "监听中 %02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    private func showDownload(_ p: Double) {
        store.statusText = String(format: "正在下载语音模型 %.0f%%", p * 100)
    }

    // MARK: - 故障

    /// 系统声音「一直没帧」—— 多半是「录制电脑音频」权限没给（拒绝了不报错，
    /// 静默给零帧，只能这样认出来）。
    ///
    /// 不中断监听：麦克风那路还能用，授权之后数据自己会来、提示自己会收。
    /// 题外一句：只要还听着，正常情况下这里永远轮不到 —— 来数据时会先报 true
    private func systemAudioState(_ alive: Bool) {
        guard listening else { return }
        if alive {
            guard store.problemAction == .grantAudioCapture else { return }
            AppDebug.log("[listen] 系统声音来了，把权限提示收掉")
            store.problem = nil
            store.problemAction = nil
        } else {
            store.problem = """
                系统声音一直没收到。屏幕上要刚弹过权限窗，点「允许」就好；
                没弹过（或点过不允许），点「去授权」去打开开关。
                """
            store.problemAction = .grantAudioCapture
        }
    }

    /// 面板上「去授权」按下去：跳系统设置（系统音频没有申请接口，只能把人
    /// 带到那一页）。授权后不用重启耳录 —— 回来点「开始监听」重试就行
    func requestAudioCapture() {
        AudioCapture.openAudioCaptureSettings()
        store.problem = "把「耳录」的开关打开，回来点「开始监听」再试一次。"
        store.problemAction = nil
    }

    private func interrupted(_ error: Error) {
        guard listening else { return }
        AppDebug.log("[listen] 采集被中断：\(error.localizedDescription)")
        Task {
            await stop()
            store.problem = "采集被中断了：\(error.localizedDescription)\n点「开始监听」再试一次"
        }
    }
}
