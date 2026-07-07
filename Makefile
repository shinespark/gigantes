DERIVED_DATA := build
APP := $(DERIVED_DATA)/Build/Products/Debug/Huemdal.app

# Apple Development 証明書があればそれで署名し、なければ ad-hoc 署名にフォールバック。
# 署名を安定させることで、リビルド後もキーチェーン ACL の再認証を不要にする。
CODE_SIGN_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development" && echo "Apple Development" || echo "-")
DEVELOPMENT_TEAM := $(shell security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p')

.PHONY: gen build test run clean

gen:
	xcodegen

build: gen
	xcodebuild -project Huemdal.xcodeproj -scheme Huemdal -configuration Debug -derivedDataPath $(DERIVED_DATA) CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)" build

test: gen
	xcodebuild -project Huemdal.xcodeproj -scheme Huemdal -destination 'platform=macOS' -derivedDataPath $(DERIVED_DATA) CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)" test

run: build
	open $(APP)

clean:
	rm -rf $(DERIVED_DATA) Huemdal.xcodeproj
