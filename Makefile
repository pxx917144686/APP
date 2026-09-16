BASEDIR = $(shell pwd)

all: ipa

ipa:
	xcodebuild -project APP.xcodeproj -scheme APP -configuration Release -sdk iphoneos -derivedDataPath build CODE_SIGNING_ALLOWED=NO
	rm -rf build/Payload APP.ipa
	mkdir -p build/Payload
	ditto build/Build/Products/Release-iphoneos/APP.app build/Payload/APP.app
	cd build && zip -qry APP.ipa Payload
	mv build/APP.ipa ./

clean:
	rm -rf build APP.ipa

.PHONY: all ipa clean
