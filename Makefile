DERIVED_DATA := build
APP := $(DERIVED_DATA)/Build/Products/Debug/Huemdal.app

.PHONY: gen build test run clean

gen:
	xcodegen

build: gen
	xcodebuild -project Huemdal.xcodeproj -scheme Huemdal -configuration Debug -derivedDataPath $(DERIVED_DATA) build

test: gen
	xcodebuild -project Huemdal.xcodeproj -scheme Huemdal -destination 'platform=macOS' -derivedDataPath $(DERIVED_DATA) test

run: build
	open $(APP)

clean:
	rm -rf $(DERIVED_DATA) Huemdal.xcodeproj
