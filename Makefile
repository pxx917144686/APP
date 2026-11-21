BASEDIR = $(shell pwd)

ifeq ($(CI),)
    RESOLVE_FLAGS = -disableAutomaticPackageResolution
endif

all: ipa

ipa:
	@/bin/zsh -o pipefail -c 'xcodebuild -project APP.xcodeproj -scheme APP -configuration Release -sdk iphoneos -derivedDataPath build $(RESOLVE_FLAGS) CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/app_build.log'
	rm -rf build/Payload APP.ipa
	mkdir -p build/Payload
	ditto build/Build/Products/Release-iphoneos/APP.app build/Payload/APP.app
	cd build && zip -qry APP.ipa Payload
	mv build/APP.ipa ./

clean:
	rm -rf build APP.ipa

# 下载器回归测试（12 场景，含分段/断点续传/停滞看门狗）
regress:
	cd tools/download-harness && ./run.sh

.PHONY: all ipa clean regress
