APP         := Tutamak
BUNDLE_ID   := local.tutamak
BUNDLE      := build/$(APP).app
BIN         := $(BUNDLE)/Contents/MacOS/$(APP)
SDK         := $(shell xcrun --show-sdk-path)
SOURCES     := $(wildcard Sources/*.swift)
ICON        := build/AppIcon.icns
INSTALL_DIR ?= $(HOME)/Applications

SWIFTFLAGS := -O -swift-version 5 -target arm64-apple-macos14.0 \
	-import-objc-header Sources/MultitouchPrivate.h \
	-F $(SDK)/System/Library/PrivateFrameworks -framework MultitouchSupport

# Accessibility permission is tied to the code signature. Ad-hoc signing resets it on every build,
# so an Apple Development identity is used when one exists.
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $$2; exit}')

# Quits the running copy and waits until it is really gone; otherwise `open` fails with error -600.
STOP = pkill -x $(APP); while pgrep -x $(APP) >/dev/null; do sleep 0.1; done

.PHONY: build run debug touches check test install uninstall clean gestures-status gestures-off gestures-restore

build: $(BIN)

$(BIN): $(SOURCES) Sources/MultitouchPrivate.h Info.plist tools/gestures.sh $(ICON)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	cp tools/gestures.sh $(BUNDLE)/Contents/Resources/gestures.sh
	cp $(ICON) $(BUNDLE)/Contents/Resources/AppIcon.icns
	swiftc $(SWIFTFLAGS) $(SOURCES) -o $(BIN)
	codesign --force --sign "$(or $(SIGN_ID),-)" --identifier $(BUNDLE_ID) $(BUNDLE)

# The icon is drawn by code (tools/make-icon.swift); no image is checked in.
$(ICON): tools/make-icon.swift
	@mkdir -p build
	rm -rf build/AppIcon.iconset
	swift tools/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o $(ICON)

# Opens it as a menu bar app.
run: build
	open $(BUNDLE)

# Opens the app and follows its log (Ctrl-C only stops following).
debug: build
	@$(STOP)
	open $(BUNDLE) --args --debug
	log stream --style compact --level info --predicate 'subsystem == "$(BUNDLE_ID)"'

# Prints raw finger frames to the terminal; does not touch any window.
touches: build
	$(BIN) --touches

# Starts up without asking for permission, prints the status and quits.
check: build
	$(BIN) --check

test:
	@mkdir -p build
	swiftc -swift-version 5 Sources/Geometry.swift Sources/GestureTracker.swift Sources/ScrollMuter.swift \
		Sources/EdgeResistance.swift Sources/Smoothing.swift Sources/DropHold.swift Sources/SystemShortcut.swift \
		Sources/SetupFlow.swift Sources/GuidePlacement.swift Tests/main.swift -o build/tests
	build/tests

install: build
	@$(STOP)
	@mkdir -p $(INSTALL_DIR)
	rm -rf $(INSTALL_DIR)/$(APP).app
	cp -R $(BUNDLE) $(INSTALL_DIR)/
	open $(INSTALL_DIR)/$(APP).app

uninstall:
	@$(STOP)
	rm -rf $(INSTALL_DIR)/$(APP).app

clean:
	rm -rf build

gestures-status:
	@tools/gestures.sh status

gestures-off:
	@tools/gestures.sh off

gestures-restore:
	@tools/gestures.sh restore
