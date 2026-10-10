.PHONY: help build universal debug run preview extract transcribe test check-bin dmg publish clean

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

## preview     离屏渲染各形态界面图到 /tmp/earshot-preview
preview: check-bin
	./build/EarShot --preview /tmp/earshot-preview

## extract     抽取链路自检（不依赖音频），例如 make extract F=testdata/sample-meeting.txt
extract: check-bin
	./build/EarShot --extract $(F)

## transcribe  语音识别自检，例如 make transcribe F=/tmp/t.aiff
transcribe: check-bin
	./build/EarShot --transcribe $(F)

# 自检类目标共用的隔离构建：产物只进 build/check-app。dist/ 里那个 app 可能
# 正挂着屏幕录制授权（ad-hoc 认 CDHash），重建就把授权抖掉，所以自检绝不碰它。
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
