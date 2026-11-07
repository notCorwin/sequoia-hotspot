.PHONY: all app test check clean
all: app
app:
	./scripts/build-app.sh
test:
	swift run HotspotCoreChecks
	swiftc -swift-version 6 -parse-as-library Sources/SequoiaHotspot/StatusIconView.swift Tests/StatusIconTests/StatusIconChecks.swift -o .build/StatusIconChecks
	.build/StatusIconChecks
check: app
	"/Applications/Sequoia Hotspot.app/Contents/MacOS/SequoiaHotspot" --check-interface
clean:
	rm -rf .build
