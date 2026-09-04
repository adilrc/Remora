XCODEGEN ?= xcodegen
SCHEME := Remora
DERIVED := .derivedData

.PHONY: generate open build release clean

generate:
	$(XCODEGEN) generate

open: generate
	open Remora.xcodeproj

build: generate
	xcodebuild -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) build

# Signed, notarized build; see scripts/release.sh for the required environment.
release:
	scripts/release.sh $(VERSION)

clean:
	rm -rf Remora.xcodeproj $(DERIVED)
