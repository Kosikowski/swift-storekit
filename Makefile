# swift-storekit

SWIFT ?= swift
XCODEBUILD ?= xcodebuild
## xcodebuild has been seen to finish a simulator test run — every test green — and
## then never exit. A test lane that cannot end is worse than one that fails, so the
## lanes that run tests run under an alarm. (perl, because macOS has no `timeout`.)
TEST_TIMEOUT ?= 1200
ALARM = perl -e 'alarm shift; exec @ARGV' $(TEST_TIMEOUT)

.PHONY: test release-tests core ios layers release-check stress integration integration-ios ui-tests demo check

## Everything that decides anything. Offline, no test host, no StoreKit: the store is
## simulated, and the clock moves only when a test moves it.
test:
	$(SWIFT) test

## The simulated store does not exist in a release build, so a test that names it
## must not either — or a consumer whose CI tests in release finds this package's own
## suite does not compile. What runs here is therefore less than half of `test`: what
## needs no simulated store, and a few tests of PurchaseStore against a store front
## that lives in Tests/. `-enable-testing` because a release build leaves it off, and
## `@testable import` needs it.
release-tests:
	$(SWIFT) test -c release -Xswiftc -enable-testing

## The logic alone.
core:
	$(SWIFT) test --filter PurchaseCoreTests

## `swift build` builds for the Mac and nothing else. A shared package elsewhere
## stopped compiling for iOS for eleven days because nothing built it, so this is
## part of `check` and not something to remember.
ios:
	$(XCODEBUILD) build -scheme swift-storekit-Package -destination 'generic/platform=iOS' \
		-derivedDataPath build/ios -quiet

## PurchaseCore is one target, so the compiler does not keep its domain pure. This does.
layers:
	./ci/layers.sh

## The simulated store hands out purchases for nothing. It must not be in a release
## build at all — absent, not disabled — and this proves it is not. A package plugin
## (Plugins/ReleaseCheck), so it is also in Xcode's menu for the package.
release-check:
	$(SWIFT) package release-check

## Races rarely show on the first run. Ten in a row, stopping at the first failure.
stress:
	@mkdir -p build; for i in 1 2 3 4 5 6 7 8 9 10; do \
		$(SWIFT) test > build/stress.log 2>&1 || { grep -E "✘|error:" build/stress.log; echo "run $$i FAILED (build/stress.log)"; exit 1; }; \
		echo "run $$i clean"; \
	done

## Real StoreKit, through the real adapter, from a test bundle hosted by an app —
## the only place SKTestSession works (spike/README.md). Needs XcodeGen.
integration:
	cd Demo && xcodegen generate --quiet
	$(ALARM) $(XCODEBUILD) test -project Demo/Demo.xcodeproj -scheme Demo -destination 'platform=macOS' \
		-derivedDataPath build/demo -quiet

## The same suite on an iOS simulator. Everything the package claims to have measured
## was measured on the Mac first; this is what says it holds on iOS too.
## An iOS 27 runtime: under Xcode 27 the test session does not attach in an iOS 26.5
## simulator at all — no products load (spike/README.md).
IOS_SIMULATOR ?= platform=iOS Simulator,name=iPhone 17,OS=latest
integration-ios:
	cd Demo && xcodegen generate --quiet
	$(ALARM) $(XCODEBUILD) test -project Demo/Demo.xcodeproj -scheme Demo -destination '$(IOS_SIMULATOR)' \
		-derivedDataPath build/demo-ios -quiet

## The app launched with a scenario, as a screenshot run launches it (docs/06). On a
## simulator, where a UI test needs no permission; on the Mac it needs Automation Mode.
ui-tests:
	cd Demo && xcodegen generate --quiet
	$(ALARM) $(XCODEBUILD) test -project Demo/Demo.xcodeproj -scheme DemoUI -destination '$(IOS_SIMULATOR)' \
		-derivedDataPath build/demo-ios -quiet

## The Demo and its hosted tests are outside the package, so nothing above compiles
## them: an API change could break `make integration` and nobody would know until the
## day before a release. Built, not run. Needs XcodeGen.
##
## Then the app again **in Release, and linked**. Nothing else here links the package
## into an optimised app, which is what an archive is — and it once did not link at
## all (docs/10-decisions.md, D25). **And looked inside**: what ships is this build,
## not SwiftPM's, and whether the package got `DEBUG` in it is decided by a heuristic
## on the configuration's name; so the release app is searched for the simulated
## store, with the debug app as the control. Then the iOS side of it and the UI tests, which
## are `#if os` branches and a target that nothing on the Mac compiles.
demo:
	cd Demo && xcodegen generate --quiet
	$(XCODEBUILD) build-for-testing -project Demo/Demo.xcodeproj -scheme Demo -destination 'platform=macOS' \
		-derivedDataPath build/demo -quiet
	$(XCODEBUILD) build -project Demo/Demo.xcodeproj -scheme Demo -configuration Release \
		-destination 'platform=macOS' -derivedDataPath build/demo-release -quiet
	$(SWIFT) package release-check --app build/demo-release/Build/Products/Release/Demo.app \
		--debug-app build/demo/Build/Products/Debug/Demo.app
	$(XCODEBUILD) build-for-testing -project Demo/Demo.xcodeproj -scheme Demo \
		-destination 'generic/platform=iOS Simulator' -derivedDataPath build/demo-ios -quiet
	$(XCODEBUILD) build-for-testing -project Demo/Demo.xcodeproj -scheme DemoUI \
		-destination 'generic/platform=iOS Simulator' -derivedDataPath build/demo-ios -quiet

check: layers test release-tests ios release-check demo
