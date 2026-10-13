.PHONY: help build universal debug run preview extract transcribe taptest taptest-run taptest-stop test check-bin dmg publish clean

help:
	@sed -n 's/^## //p' $(MAKEFILE_LIST)

## build       构建到 dist/EarShot.app（本机架构）
build:
	./build.sh

## universal   构建通用二进制（arm64 + x86_64）
universal:
	./build.sh --clean --universal

## debug       不优化、带调试符号
debug:
	./build.sh --clean --debug

## run         构建并启动
run:
	./run.sh

## test        离线自检全套（不需要 GUI / 权限；CI 跑的是同一套；不碰 dist/）
test: check-bin
	./build/EarShot --senttest
	./build/EarShot --settingstest
	./build/EarShot --wavetest
	./build/EarShot --pcmtest
	./build/EarShot --echotest
	./build/EarShot --states
	./build/EarShot --hittest 200 300 4
	./build/EarShot --hittest 200 324 4 0 --heights 116,130.5,145,130.5

## preview     离屏渲染各形态界面图到 /tmp/earshot-preview
preview: check-bin
	./build/EarShot --preview /tmp/earshot-preview

## extract     抽取链路自检（不依赖音频），例如 make extract F=testdata/sample-meeting.txt
extract: check-bin
	./build/EarShot --extract $(F)

## transcribe  语音识别自检，例如 make transcribe F=/tmp/t.aiff
transcribe: check-bin
	./build/EarShot --transcribe $(F)

# tap 探针必须用 open 独立启动：终端直跑时 TCC 把责任进程算在终端头上，
# 终端没有录音权限说明键，连弹窗都被拒（tap 建了但全是零，见 Sources/TapProbe.swift）。
# 代价是 stdout 没了终端，探针 --log 写文件，这里 tail 跟着。Ctrl-C 退出的只是
# tail，探针还在跑，要停用 taptest-stop。
TAPLOG := /tmp/earshot-taptest.log

## taptest     tap 锁屏收音探针（构建 → 独立进程启动 → 跟日志；要音频录制权限 + 真人锁一次屏）
taptest: check-bin
	@rm -f $(TAPLOG) && touch $(TAPLOG)
	open -n "$(CURDIR)/build/check-app/EarShot.app" --args --taptest $(S) --log $(TAPLOG)
	tail -f $(TAPLOG)

## taptest-run 不重建直接跑探针（重建会让 ad-hoc 授权失效，重复实验用这个）
taptest-run:
	@rm -f $(TAPLOG) && touch $(TAPLOG)
	open -n "$(CURDIR)/build/check-app/EarShot.app" --args --taptest $(S) --log $(TAPLOG)
	tail -f $(TAPLOG)

# pkill -f 匹配的是整条命令行：模式串不加 [E] 会连「正在跑 pkill 的这个 sh」
# 一起匹配上，把 stop 本行杀在半路（- 前缀只是兜着不让 make 报错）。
## taptest-stop 提前停掉探针并把小结打出来（正常等它跑满也行）
taptest-stop:
	-pkill -f "[E]arShot --taptest"
	@sleep 1
	@tail -n 30 $(TAPLOG)

# 自检类目标共用的隔离构建：产物只进 build/check-app。dist/ 里那个 app 可能
# 正挂着音频采集授权（ad-hoc 认 CDHash），重建就把授权抖掉，所以自检绝不碰它。
## check-bin   自检类目标共用的隔离构建（不动 dist/）
check-bin:
	DIST_DIR="$(CURDIR)/build/check-app" ./build.sh

## dmg         打包发布 DMG 到 release/（通用二进制，不动 dist/）
dmg:
	./release.sh

## publish     打 DMG 并发布 GitHub Release（tag v<版本>，需 gh 已登录）
publish:
	./release.sh --publish

## clean       清掉构建产物
clean:
	rm -rf build dist release
