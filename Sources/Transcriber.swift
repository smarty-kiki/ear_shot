import AVFoundation
import Foundation
import Speech

/// 一路识别出来的一段结果。
enum TranscribeEvent {
    /// 未定稿：这句话还在变，只够拿去显示「正在说」，不喂给抽取器
    case volatile(String)
    /// 定稿：可以拿去抽待办了
    case final(String)
}

enum TranscribeError: Error, CustomStringConvertible {
    case engineUnavailable
    case localeUnsupported(Locale)
    case noAudioFormat

    var description: String {
        switch self {
        case .engineUnavailable:
            return "这台机器上 SpeechTranscriber 不可用"
        case .localeUnsupported(let l):
            return "系统语音模型不支持 \(l.identifier)"
        case .noAudioFormat:
            return "拿不到识别器要的音频格式"
        }
    }
}

/// 一路音频的识别管线（麦克风一条、系统声音一条）。
///
/// 苹果这套是全本地的：音频不出机器，模型一次下载后离线可用 —— 这也是选它
/// 而不是云端 ASR 的原因。一个来源一个 `SpeechAnalyzer`，互不干扰。
///
/// 线程约定：`feed(_:)` **必须在同一条队列上调用**（`AVAudioConverter` 不是
/// 线程安全的）。`AudioCapture` 给每路各开一条采集队列，正好一一对应。
final class Transcriber: @unchecked Sendable {

    let speaker: Speaker
    /// 识别器要的输入格式（本机上是 16kHz 单声道 Int16）
    let inputFormat: AVAudioFormat

    private let analyzer: SpeechAnalyzer
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private let resultsTask: Task<Void, Never>
    private let reservedLocale: Locale?

    /// 采集队列专用（见类型注释），格式变了就重建
    private var converter: AVAudioConverter?

    private init(speaker: Speaker, analyzer: SpeechAnalyzer, inputFormat: AVAudioFormat,
                 inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
                 resultsTask: Task<Void, Never>, reservedLocale: Locale?) {
        self.speaker = speaker
        self.analyzer = analyzer
        self.inputFormat = inputFormat
        self.inputBuilder = inputBuilder
        self.resultsTask = resultsTask
        self.reservedLocale = reservedLocale
    }

    // MARK: - 起停

    /// 建好一路管线并开始跑。
    ///
    /// - Parameters:
    ///   - onEvent: 每次识别结果回调。**在任意线程上**，调用方自己跳回主线程。
    ///   - onDownloadProgress: 模型下载进度 0…1；不需要下载时不回调。
    static func start(speaker: Speaker,
                      locale: Locale,
                      onDownloadProgress: (@Sendable (Double) -> Void)? = nil,
                      onEvent: @escaping @Sendable (TranscribeEvent) async -> Void) async throws -> Transcriber {
        let module = try await ensureAssets(locale: locale, onProgress: onDownloadProgress)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscribeError.noAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)

        let resultsTask = Task {
            do {
                for try await r in module.results {
                    let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    await onEvent(r.isFinal ? .final(text) : .volatile(text))
                }
            } catch is CancellationError {
                // 停的时候主动取消的，不算事
            } catch {
                AppDebug.log("[transcriber/\(speaker.label)] 结果流断了：\(error.localizedDescription)")
            }
        }

        AppDebug.log("[transcriber/\(speaker.label)] 已启动，输入格式 \(format)")
        return Transcriber(speaker: speaker, analyzer: analyzer, inputFormat: format,
                           inputBuilder: builder, resultsTask: resultsTask,
                           reservedLocale: module.selectedLocales.first)
    }

    /// 收工：把剩下的音频推完、等识别器把最后一句定稿。
    func stop() async {
        inputBuilder.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            AppDebug.log("[transcriber/\(speaker.label)] 收尾失败：\(error.localizedDescription)")
        }
        // finalize 返回时结果已经吐完了，取消是收个尾
        resultsTask.cancel()
        if let l = reservedLocale {
            _ = await AssetInventory.release(reservedLocale: l)
        }
        AppDebug.log("[transcriber/\(speaker.label)] 已停止")
    }

    // MARK: - 喂音频

    /// 喂一帧。格式对不上就重采样（含 Float32→Int16、48k→16k、多声道→单声道）。
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer), converted.frameLength > 0 else { return }
        inputBuilder.yield(AnalyzerInput(buffer: converted))
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == inputFormat { return buffer }

        if converter == nil || converter?.inputFormat != buffer.format {
            guard let c = AVAudioConverter(from: buffer.format, to: inputFormat) else {
                AppDebug.log("[transcriber/\(speaker.label)] 建不出转换器：\(buffer.format) → \(inputFormat)")
                return nil
            }
            // 流式：不做预滚，免得开头多出一截静音
            c.primeMethod = .none
            c.downmix = true          // 多声道麦克风直接压成单声道
            converter = c
        }
        guard let converter else { return nil }

        let ratio = inputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: capacity) else { return nil }

        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let err {
            // 单帧失败不致命：丢一帧而已，下一个包还会来
            AppDebug.log("[transcriber/\(speaker.label)] 重采样失败：\(err.localizedDescription)")
            return nil
        }
        return out
    }

    // MARK: - 模型资产

    /// 拿到能用的识别模块：支持这个语言、模型已就位（没装就先下）。
    ///
    /// 中文模型几百 MB，首次用要下 —— 一起走 `onProgress` 报出去，界面上要
    /// 有东西可看，不能让用户对着黑屏猜。
    @discardableResult
    static func ensureAssets(locale: Locale,
                             onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw TranscribeError.engineUnavailable }
        guard let real = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscribeError.localeUnsupported(locale)
        }
        let module = SpeechTranscriber(locale: real, preset: .progressiveTranscription)

        if await AssetInventory.status(forModules: [module]) != .installed,
           let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            AppDebug.log("[transcriber] 开始下载 \(real.identifier) 语音模型")
            onProgress?(0)
            let progress = req.progress
            let ticker = Task {
                while !progress.isFinished && !progress.isCancelled {
                    onProgress?(progress.fractionCompleted)
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
            defer { ticker.cancel() }
            try await req.downloadAndInstall()
            onProgress?(1)
            AppDebug.log("[transcriber] 模型就绪")
        }

        // 占个位，免得跑到一半模型被系统回收。占不上（配额满）也不致命
        _ = try? await AssetInventory.reserve(locale: real)
        return module
    }
}

// MARK: - 文件自检

/// 识别链路自检：拿一个音频文件跑一遍真识别，不碰采集、不碰权限。
///
/// 用法：`EarShot --transcribe <音频文件> [--locale zh-CN] [--verbose]`
///
/// 顺带把「送给抽取器的窗口」原样打出来 —— 转写缓冲是这一段的产物，
/// 打出来才算真的验过。
enum TranscribeSelfCheck {

    static func run(path: String, locale: String, verbose: Bool) async -> Int32 {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("找不到文件：\(path)")
            return 2
        }
        guard let file = try? AVAudioFile(forReading: url) else {
            print("打不开音频（只支持 wav/aiff/m4a 这类 CoreAudio 认得出来的）：\(path)")
            return 2
        }
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        print("音频 \(url.lastPathComponent)  \(String(format: "%.1f", seconds)) 秒  \(file.fileFormat)")

        let module: SpeechTranscriber
        do {
            module = try await Transcriber.ensureAssets(locale: Locale(identifier: locale)) { p in
                print(String(format: "\r下载语音模型 %.0f%%", p * 100), terminator: "")
                fflush(stdout)
            }
            print("")   // 下载进度那行收个尾
        } catch {
            print("准备识别器失败：\(error)")
            return 1
        }

        let log = TranscriptLog()
        let started = Date()
        do {
            let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [module],
                                                    finishAfterFile: true)
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)

            for try await r in module.results {
                let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if r.isFinal {
                    log.finalize(.other, text: text)      // 文件里没有说话人，整段算「对方」
                    print("● \(text)")
                } else if verbose {
                    print("… \(text)")
                }
            }
        } catch {
            print("识别失败：\(error.localizedDescription)")
            return 1
        }

        let wall = Date().timeIntervalSince(started)
        print(String(repeating: "-", count: 70))
        print(String(format: "定稿 %d 段、%d 字，耗时 %.1f 秒（%.2f× 实时）",
                     log.finalizedCount, log.totalChars, wall,
                     seconds > 0 ? seconds / max(wall, 0.001) : 0))
        print("送给抽取器的窗口（末尾 \(min(log.totalChars, 1200)) 字）：")
        print(log.recentWindow(chars: 1200))
        if log.finalizedCount == 0 {
            print("（一段都没定稿 —— 音频没声音 / 语言不对 / 模型不对，都长这样）")
            return 1
        }
        return 0
    }
}
