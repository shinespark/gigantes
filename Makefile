DERIVED_DATA := build
APP := $(DERIVED_DATA)/Build/Products/Debug/Huemdal.app

# ad-hoc 署名はビルドごとに署名が変わり、Keychain の ACL が毎回無効になって
# パスワードを求められる。ローカルでは Apple Development で署名して署名を
# 安定させる。CI(証明書なし・CI=true)では ad-hoc のまま。
ifeq ($(CI),)
SIGNING := CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=39G2898H69
endif

.PHONY: gen build test run clean

gen:
	xcodegen

build: gen
	xcodebuild -project Huemdal.xcodeproj -scheme Huemdal -configuration Debug -derivedDataPath $(DERIVED_DATA) $(SIGNING) build

test: gen
	xcodebuild -project Huemdal.xcodeproj -scheme Huemdal -destination 'platform=macOS' -derivedDataPath $(DERIVED_DATA) $(SIGNING) test

run: build
	open $(APP)

clean:
	rm -rf $(DERIVED_DATA) Huemdal.xcodeproj
