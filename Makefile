DERIVED_DATA := build
APP := $(DERIVED_DATA)/Build/Products/Debug/Gigantes.app

.PHONY: gen build test run clean

gen:
	xcodegen

build: gen
	xcodebuild -project Gigantes.xcodeproj -scheme Gigantes -configuration Debug -derivedDataPath $(DERIVED_DATA) build

test: gen
	xcodebuild -project Gigantes.xcodeproj -scheme Gigantes -destination 'platform=macOS' -derivedDataPath $(DERIVED_DATA) test

run: build
	open $(APP)

clean:
	rm -rf $(DERIVED_DATA) Gigantes.xcodeproj
