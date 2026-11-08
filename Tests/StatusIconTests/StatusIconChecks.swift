import AppKit

// Offscreen rendering only: never orders a window or changes the live network.
@main struct StatusIconChecks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        defer { window.close() }

        for height: CGFloat in [22, 24] {
            let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 26, height: height))
            button.imagePosition = .imageOnly
            button.isBordered = false
            window.contentView!.addSubview(button)
            let icon = StatusIconView()
            icon.install(in: button)

            var online: Mask?
            for offline in [false, true, false, true, false] {
                // Exercise the same view and update method used by the application.
                icon.update(isOffline: offline, reduceMotion: false)
                expect(button.image == nil, "A second renderer replaced the status icon")
                expect(icon.frame.midY == button.bounds.midY, "The image canvas moved vertically")
                // Compare settled glyphs: replacement intentionally moves layers off-canvas.
                if offline {
                    let frame = icon.frame
                    icon.update(isOffline: true, reduceMotion: true)
                    expect(icon.frame == frame, "Reduced Motion moved the icon")
                }
                let mask = snapshot(button)
                if offline {
                    checkAlignment(online!, mask)
                    icon.update(isOffline: true, reduceMotion: false)
                } else if let online {
                    expect(mask == online, "Returning from an active replacement changed the online icon")
                } else {
                    online = mask
                }
            }
            if height == 22 { checkRepetition(icon) }
            checkTint(icon)
            icon.removeFromSuperview()
            button.removeFromSuperview()
        }
        print("Status icons stay aligned and render opaque in light and dark appearances.")
    }

    @MainActor private final class ImageChanges {
        var count = 0
    }

    @MainActor private static func checkRepetition(_ icon: StatusIconView) {
        icon.update(isOffline: false, reduceMotion: true)
        let changes = ImageChanges()
        let observation = icon.observe(\.image) { _, _ in
            MainActor.assumeIsolated { changes.count += 1 }
        }
        defer { observation.invalidate() }

        icon.update(isOffline: true, reduceMotion: false)
        let initial = changes.count
        for _ in 0..<5 { icon.update(isOffline: true, reduceMotion: false) }
        expect(changes.count == initial, "Status updates restarted an active replacement")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.75))
        expect(changes.count >= initial + 2, "Offline replacement stopped after its first cycle")

        icon.update(isOffline: true, reduceMotion: true)
        let reduced = changes.count
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.9))
        expect(changes.count == reduced, "Reduced Motion left offline replacement running")

        icon.update(isOffline: true, reduceMotion: false)
        expect(changes.count > reduced, "Offline replacement did not resume")
        icon.update(isOffline: false, reduceMotion: false)
        let online = changes.count
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.9))
        expect(changes.count == online, "Offline replacement continued after reconnecting")
    }

    @MainActor private static func checkTint(_ icon: StatusIconView) {
        // Reuse the same view to catch colors frozen to the initial appearance.
        for appearance in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            icon.window!.appearance = NSAppearance(named: appearance)
            for offline in [false, true] {
                icon.update(isOffline: offline, reduceMotion: true)
                for emphasized in [false, true, false] {
                    icon.setEmphasized(emphasized)
                    var expected = NSColor.black
                    icon.effectiveAppearance.performAsCurrentDrawingAppearance {
                        expected = (emphasized ? NSColor.selectedMenuItemTextColor
                                    : NSColor.labelColor.withAlphaComponent(1)).usingColorSpace(.sRGB)!
                    }
                    let bitmap = icon.bitmapImageRepForCachingDisplay(in: icon.bounds)!
                    icon.cacheDisplay(in: icon.bounds, to: bitmap)
                    var solidPixels = 0
                    for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                        let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                        guard color.alphaComponent > 0.99 else { continue }
                        solidPixels += 1
                        expect(abs(color.redComponent - expected.redComponent) < 0.01 &&
                               abs(color.greenComponent - expected.greenComponent) < 0.01 &&
                               abs(color.blueComponent - expected.blueComponent) < 0.01,
                               "Status icon tint does not match its appearance or menu highlight")
                    } }
                    expect(solidPixels > 0, "Status icon is translucent in \(appearance.rawValue)")
                }
            }
        }
    }

    private struct Mask: Equatable {
        let width: Int
        let height: Int
        let pixels: [Bool]
    }

    @MainActor private static func snapshot(_ view: NSView) -> Mask {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let alpha = (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).map { x in bitmap.colorAt(x: x, y: y)!.alphaComponent }
        }
        let maximum = alpha.max()!
        expect(maximum > 0, "The status icon did not render")
        return Mask(width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
                    pixels: alpha.map { $0 > maximum * 0.2 })
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            FileHandle.standardError.write(Data("\(message)\n".utf8))
            exit(1)
        }
    }

    private static func checkAlignment(_ online: Mask, _ offline: Mask) {
        expect(online.width == offline.width && online.height == offline.height,
                     "Switching icons resized the status button")
        func overlap(dx: Int, dy: Int) -> Int {
            var matches = 0
            for y in 0..<online.height { for x in 0..<online.width {
                let targetX = x + dx, targetY = y + dy
                guard targetX >= 0, targetX < offline.width,
                      targetY >= 0, targetY < offline.height else { continue }
                if online.pixels[y * online.width + x],
                   offline.pixels[targetY * offline.width + targetX] { matches += 1 }
            } }
            return matches
        }
        // Compare the existing chain instead of bounds expanded by the extra slash.
        let aligned = overlap(dx: 0, dy: 0)
        for dy in -3...3 { for dx in -3...3 {
            expect(aligned >= overlap(dx: dx, dy: dy),
                         "Online/offline chain alignment differs by (\(dx), \(dy)) pixels")
        } }
    }
}
