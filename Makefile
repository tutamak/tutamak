# Two flavors of one app, told apart by identity so both can live on the same Mac:
#
#   dev (default)  "Tutamak Dev", local.tutamak, build/dev/TutamakDev.app. No update feed: a
#                  development copy must never offer to replace itself with the release.
#                  `make install` puts it in ~/Applications.
#   release        "Tutamak", dev.tutamak.tutamak, build/release/Tutamak.app. Developer ID with the
#                  hardened runtime, notarized, and the update feed. Built by `make release`;
#                  people install it from the disk image into /Applications.
#
# The two must not run at once (both would act on every gesture); each warns in its menu when it
# sees the other.
FLAVOR      ?= dev
VERSION     ?= $(shell cat VERSION)
REPO        := tutamak/tutamak
SDK         := $(shell xcrun --show-sdk-path)
SOURCES     := $(wildcard Sources/*.swift)
ICON        := build/AppIcon.icns

ifeq ($(FLAVOR),release)
APP         := Tutamak
NAME        := Tutamak
BUNDLE_ID   := dev.tutamak.tutamak
OUT         := build/release
INSTALL_DIR ?= /Applications
FEED_URL    ?= https://github.com/$(REPO)/releases/latest/download/appcast.xml
SIGN_ID     ?= $(shell security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
else
APP         := TutamakDev
NAME        := Tutamak Dev
BUNDLE_ID   := local.tutamak
OUT         := build/dev
INSTALL_DIR ?= $(HOME)/Applications
FEED_URL    :=
# Accessibility permission is tied to the code signature. Ad-hoc signing resets it on every
# build, so an Apple Development identity is used when one exists.
SIGN_ID     ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $$2; exit}')
endif

BUNDLE      := $(OUT)/$(APP).app
BIN         := $(BUNDLE)/Contents/MacOS/$(APP)
PLIST       := $(BUNDLE)/Contents/Info.plist
# Notarization requires the hardened runtime and a secure timestamp; only a Developer ID build
# goes to Apple, so only it carries them. No entitlements: the app is not sandboxed and uses no JIT.
HARDENED    := $(if $(findstring Developer ID Application,$(SIGN_ID)),--options runtime --timestamp,)
SIGN        := codesign --force --sign "$(or $(SIGN_ID),-)" $(HARDENED)

# Sparkle 2, the updater: pinned by version and digest, downloaded once, never checked in.
# The public half of the EdDSA key that signs every update; the secret half is in the keychain of
# the Mac that releases (Sparkle's generate_keys), and losing it means installed copies can never
# be updated again.
SPARKLE_VERSION := 2.10.0
SPARKLE_SHA256  := c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
SPARKLE_DIR     := build/sparkle-$(SPARKLE_VERSION)
SPARKLE_KEY     := WC9PPr7SL5v2LvmQShrOYVEawDoB5wWngrinpVZE6Tw=
FRAMEWORK       := $(BUNDLE)/Contents/Frameworks/Sparkle.framework

SWIFTFLAGS := -O -swift-version 5 -target arm64-apple-macos26.0 \
	-import-objc-header Sources/MultitouchPrivate.h \
	-F $(SDK)/System/Library/PrivateFrameworks -framework MultitouchSupport \
	-F $(SPARKLE_DIR) -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks

# Quits the running copy of this flavor and waits until it is really gone; otherwise `open`
# fails with error -600.
STOP = pkill -x $(APP); while pgrep -x $(APP) >/dev/null; do sleep 0.1; done

.PHONY: build run debug touches check test install uninstall clean gestures-status gestures-off \
	gestures-restore release publish ship _release _publish dmgbuild

build: $(BIN)

$(BIN): $(SOURCES) Sources/MultitouchPrivate.h Info.plist.in VERSION LICENSE tools/gestures.sh $(ICON) \
		$(SPARKLE_DIR)/.verified
	@echo '$(VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' || { echo "build: version '$(VERSION)' is not x.y.z"; exit 1; }
	rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources $(BUNDLE)/Contents/Frameworks
	sed -e 's/@EXECUTABLE@/$(APP)/g' -e 's/@BUNDLE_ID@/$(BUNDLE_ID)/g' -e 's/@NAME@/$(NAME)/g' \
		-e 's/@VERSION@/$(VERSION)/g' Info.plist.in > $(PLIST)
	@if [ -n '$(FEED_URL)' ]; then \
		plutil -insert SUFeedURL -string '$(FEED_URL)' $(PLIST) && \
		plutil -insert SUPublicEDKey -string '$(SPARKLE_KEY)' $(PLIST) && \
		plutil -insert SUEnableAutomaticChecks -bool YES $(PLIST); fi
	plutil -lint -s $(PLIST)
	cp tools/gestures.sh $(BUNDLE)/Contents/Resources/gestures.sh
	cp $(ICON) $(BUNDLE)/Contents/Resources/AppIcon.icns
	cp LICENSE $(BUNDLE)/Contents/Resources/LICENSE
	cp $(SPARKLE_DIR)/LICENSE $(BUNDLE)/Contents/Resources/Sparkle-LICENSE
	@# `ditto` keeps the framework's Versions/Current symlinks. The XPC services are only for
	@# sandboxed apps, and Tutamak is not one: two fewer things to sign and notarize.
	ditto $(SPARKLE_DIR)/Sparkle.framework $(FRAMEWORK)
	rm -rf $(FRAMEWORK)/XPCServices $(FRAMEWORK)/Versions/B/XPCServices
	swiftc $(SWIFTFLAGS) $(SOURCES) -o $(BIN)
	@# Inside out: each nested executable before what contains it, the app last. `--deep` would
	@# sign them all with the app's options, which Apple advises against for anything shipped.
	$(SIGN) $(FRAMEWORK)/Versions/B/Autoupdate
	$(SIGN) $(FRAMEWORK)/Versions/B/Updater.app
	$(SIGN) $(FRAMEWORK)
	$(SIGN) --identifier $(BUNDLE_ID) $(BUNDLE)
	codesign --verify --deep --strict $(BUNDLE)

$(SPARKLE_DIR)/.verified:
	rm -rf $(SPARKLE_DIR) && mkdir -p $(SPARKLE_DIR)
	curl -fsSL -o $(SPARKLE_DIR).tar.xz \
		https://github.com/sparkle-project/Sparkle/releases/download/$(SPARKLE_VERSION)/Sparkle-$(SPARKLE_VERSION).tar.xz
	@echo '$(SPARKLE_SHA256)  $(SPARKLE_DIR).tar.xz' | shasum -a 256 -c - >/dev/null || \
		{ echo "sparkle: the download's digest does not match"; rm -f $(SPARKLE_DIR).tar.xz; exit 1; }
	tar -xJf $(SPARKLE_DIR).tar.xz -C $(SPARKLE_DIR) && rm -f $(SPARKLE_DIR).tar.xz
	touch $@

# The icon is drawn by code (tools/make-icon.swift); no image is checked in.
$(ICON): tools/make-icon.swift
	@mkdir -p build
	rm -rf build/AppIcon.iconset
	swift tools/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o $(ICON)

# Opens the app; it lives in the menu bar.
run: build
	open $(BUNDLE)

# Opens the app and follows its log (Ctrl-C stops following; the app keeps running).
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
		Sources/EdgeResistance.swift Sources/Smoothing.swift Sources/DropHold.swift Sources/SystemShortcut.swift Sources/Placements.swift \
		Sources/SetupFlow.swift Sources/GuidePlacement.swift Sources/Flavor.swift Tests/main.swift -o build/tests
	build/tests
	@tools/release-notes.sh --self-test

install: build
	@$(STOP)
	@mkdir -p $(INSTALL_DIR)
	rm -rf $(INSTALL_DIR)/$(APP).app
	ditto $(BUNDLE) $(INSTALL_DIR)/$(APP).app
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

# ---------------------------------------------------------------------------------------------
# Releasing a version, on the Mac that holds the Developer ID identity, the notarytool profile
# and Sparkle's key:
#
#   make release   gates, then builds, signs, notarizes and staples the release flavor, and writes
#                  build/release/v<version>/: the update's zip, the disk image, the appcast, the
#                  notes and the commit built. Apart from notarization nothing leaves the Mac.
#   make publish   tags that commit v<version>, pushes the tag and opens the GitHub release with
#                  the disk image, the zip and the appcast.
#   make ship      release, push main, publish: the whole thing on main.
#
# The split is the point: the release is tried on this Mac before anyone can download it.
#
# Gates: the version (VERSION) is x.y.z, the tree is clean (the release is a known commit),
# v<version> is not tagged here or on GitHub, the tests pass, and CHANGELOG.md has a non-empty
# `## [<version>]` section: it becomes the notes on the release page and in the update window.
#
# Two archives of the same stapled app, for two readers. The zip is Sparkle's: the appcast names
# it by version. The disk image is a person's first install, the app beside an Applications link;
# its name carries no version, so releases/latest/download/Tutamak.dmg never goes stale. Both
# are checked the way they arrive: unpacked or mounted, then verified, assessed and validated.
# Zips carry no extended attributes: ditto would store them as `._` files that, unzipped beside
# Sparkle.framework's symlinks, break its seal and make Gatekeeper call the app damaged.
#
# The appcast has one item: releases/latest/download/appcast.xml always serves the newest
# release's, so the newest item is the only one any installed copy reads. Publishing a release is
# publishing the update. A broken release is fixed by a newer one: Sparkle never goes back.
NOTARY_PROFILE ?= evlat
# The disk image is laid out by dmgbuild (tools/dmg-settings.py), pinned with its dependencies and
# installed into a virtual environment under build/ on the first release; it never enters the repo.
DMGBUILD_VERSION := 1.6.7
DMGBUILD_DIR     := build/dmgbuild-$(DMGBUILD_VERSION)
RELEASE_DIR    := build/release/v$(VERSION)
ZIP            := $(RELEASE_DIR)/Tutamak-$(VERSION).zip
DMG            := $(RELEASE_DIR)/Tutamak.dmg
NOTES          := $(RELEASE_DIR)/notes.md
RELEASE_URL    := https://github.com/$(REPO)/releases/download/v$(VERSION)/

release:
	$(MAKE) FLAVOR=release _release

dmgbuild:
	@test -x $(DMGBUILD_DIR)/bin/dmgbuild && exit 0; \
	rm -rf $(DMGBUILD_DIR) && python3 -m venv $(DMGBUILD_DIR) && \
	$(DMGBUILD_DIR)/bin/pip install -q --disable-pip-version-check \
		dmgbuild==$(DMGBUILD_VERSION) ds_store==1.3.3 mac_alias==2.2.3 || \
		{ echo "dmgbuild: could not be installed (python3 -m venv and pip, from PyPI)"; rm -rf $(DMGBUILD_DIR); exit 1; }

publish:
	$(MAKE) FLAVOR=release _publish

ship:
	@test "$$(git branch --show-current)" = main || { echo "ship: the branch is not main"; exit 1; }
	$(MAKE) release
	git push origin main
	$(MAKE) publish

# Sends $(1) to Apple and staples the ticket to $(2).
define notarize
	out=$$(xcrun notarytool submit $(1) --keychain-profile '$(NOTARY_PROFILE)' --wait 2>&1) || true; \
	echo "$$out" | tail -n 2; \
	echo "$$out" | grep -q 'status: Accepted' || { \
		id=$$(echo "$$out" | sed -n 's/^ *id: //p' | head -n 1); \
		echo "release: notarization was not accepted$${id:+; details: xcrun notarytool log $$id --keychain-profile $(NOTARY_PROFILE)}"; \
		exit 1; }; \
	xcrun stapler staple -q $(2) && xcrun stapler validate -q $(2)
endef

# Checks an app the way a person gets it: sealed, notarized, ticket stapled.
define verify_app
	codesign --verify --deep --strict $(1) && \
	spctl -a -vv -t exec $(1) 2>&1 | grep -q 'source=Notarized Developer ID' && \
	xcrun stapler validate -q $(1) || { echo "release: $(1) does not pass Gatekeeper"; spctl -a -vv -t exec $(1); exit 1; }
endef

_release: dmgbuild
	@echo '$(VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' || { echo "release: version '$(VERSION)' is not x.y.z"; exit 1; }
	@test -z "$$(git status --porcelain)" || { echo "release: the working tree is not clean; a release is built from a known commit"; exit 1; }
	@! git rev-parse -q --verify 'refs/tags/v$(VERSION)' >/dev/null || { echo "release: v$(VERSION) is already tagged; raise VERSION"; exit 1; }
	@! git ls-remote --exit-code --tags origin 'refs/tags/v$(VERSION)' >/dev/null || { echo "release: v$(VERSION) is already tagged on GitHub"; exit 1; }
	@case '$(SIGN_ID)' in "Developer ID Application:"*) ;; *) echo "release: no Developer ID Application identity in the keychain"; exit 1;; esac
	rm -rf $(RELEASE_DIR) && mkdir -p $(RELEASE_DIR)
	@tools/release-notes.sh '$(VERSION)' > $(NOTES); \
	grep -q '[^[:space:]]' $(NOTES) || { echo "release: CHANGELOG.md has no '## [$(VERSION)]' section, or it is empty"; exit 1; }
	$(MAKE) test
	rm -rf $(BUNDLE)
	$(MAKE) FLAVOR=release build
	@test "$$(plutil -extract SUFeedURL raw $(PLIST))" = '$(FEED_URL)' || { echo "release: the app's feed is not $(FEED_URL)"; exit 1; }
	@echo "release: sending the app to Apple for notarization (a few minutes)"
	ditto -c -k --norsrc --noextattr --keepParent $(BUNDLE) $(RELEASE_DIR)/notarize.zip
	@$(call notarize,$(RELEASE_DIR)/notarize.zip,$(BUNDLE))
	rm -f $(RELEASE_DIR)/notarize.zip
	ditto -c -k --norsrc --noextattr --keepParent $(BUNDLE) $(ZIP)
	$(DMGBUILD_DIR)/bin/dmgbuild -s tools/dmg-settings.py -D app=$(BUNDLE) Tutamak $(DMG)
	codesign --force --sign "$(SIGN_ID)" --timestamp $(DMG)
	@echo "release: sending the disk image to Apple for notarization"
	@$(call notarize,$(DMG),$(DMG))
	@spctl -a -vv -t open --context context:primary-signature $(DMG) 2>&1 | grep -q 'source=Notarized Developer ID' || \
		{ echo "release: the disk image does not pass Gatekeeper"; exit 1; }
	@# What people download, checked as they get it: the zip unpacked, the disk image mounted.
	rm -rf $(RELEASE_DIR)/check && mkdir -p $(RELEASE_DIR)/check/zip $(RELEASE_DIR)/check/dmg
	ditto -x -k $(ZIP) $(RELEASE_DIR)/check/zip
	@$(call verify_app,$(RELEASE_DIR)/check/zip/Tutamak.app)
	hdiutil attach -quiet -nobrowse -readonly -mountpoint $(RELEASE_DIR)/check/dmg $(DMG)
	@( $(call verify_app,$(RELEASE_DIR)/check/dmg/Tutamak.app) ); status=$$?; \
		hdiutil detach -quiet $(RELEASE_DIR)/check/dmg; exit $$status
	rm -rf $(RELEASE_DIR)/check
	tools/make-appcast.sh $(SPARKLE_DIR)/bin/sign_update $(BUNDLE) $(ZIP) '$(RELEASE_URL)Tutamak-$(VERSION).zip' \
		$(RELEASE_DIR)/appcast.xml $(NOTES)
	git rev-parse HEAD > $(RELEASE_DIR)/commit
	@echo "release: $(RELEASE_DIR) ($$(cat $(RELEASE_DIR)/commit)); try it, then: make publish"

_publish:
	@for f in Tutamak-$(VERSION).zip Tutamak.dmg appcast.xml notes.md commit; do \
		test -f $(RELEASE_DIR)/$$f || { echo "publish: $(RELEASE_DIR)/$$f is missing; run make release first"; exit 1; }; done
	@! git ls-remote --exit-code --tags origin 'refs/tags/v$(VERSION)' >/dev/null || { echo "publish: v$(VERSION) is already tagged on GitHub"; exit 1; }
	git fetch -q origin main
	@git merge-base --is-ancestor "$$(cat $(RELEASE_DIR)/commit)" origin/main || { echo "publish: the built commit is not on origin/main; push main first"; exit 1; }
	git tag -a 'v$(VERSION)' -m 'Tutamak $(VERSION)' "$$(cat $(RELEASE_DIR)/commit)"
	git push origin 'v$(VERSION)'
	gh release create 'v$(VERSION)' $(DMG) $(ZIP) $(RELEASE_DIR)/appcast.xml --repo '$(REPO)' --verify-tag --latest \
		--title 'Tutamak $(VERSION)' --notes-file $(NOTES)
	@echo "publish: https://github.com/$(REPO)/releases/tag/v$(VERSION)"
