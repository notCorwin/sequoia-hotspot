.PHONY: all app test check clean
all: app
app:
	./scripts/build-app.sh
test:
	swift run HotspotCoreChecks
check: app
	"dist/Sequoia Hotspot.app/Contents/MacOS/SequoiaHotspot" --check-interface
clean:
	rm -rf .build dist
