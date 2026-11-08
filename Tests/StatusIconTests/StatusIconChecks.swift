import AppKit
import QuartzCore

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
        print("Status icons stay aligned and opaque; layered rendered frames move across three animation cycles.")
    }

    @MainActor private static func checkRepetition(_ icon: StatusIconView) {
        func parts() -> [CALayer] {
            (icon.layer?.sublayers ?? []).filter { !($0.animationKeys() ?? []).isEmpty }
        }
        func run(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
        }
        icon.update(isOffline: true, reduceMotion: false)
        CATransaction.flush()
        let layers = parts()
        expect(layers.count > 1, "Offline icon does not animate separate layers")
        for _ in 0..<5 { icon.update(isOffline: true, reduceMotion: false) }
        expect(parts() == layers, "Status updates recreated active animation layers")

        var frames = Set<Data>()
        var movingCycles = Set<Int>()
        var coverage: [Int] = []
        let start = CACurrentMediaTime()
        for _ in 0..<76 {
            run(0.05)
            let elapsed = CACurrentMediaTime() - start
            for part in layers {
                if let frame = part.presentation(), frame.opacity < 0.95,
                   abs(frame.transform.m11 - 1) > 0.01 {
                    movingCycles.insert(Int(elapsed / 1.6))
                }
            }
            let context = CGContext(data: nil, width: 88, height: 72, bitsPerComponent: 8,
                                    bytesPerRow: 88 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.scaleBy(x: 4, y: 4)
            icon.layer!.presentation()!.render(in: context)
            let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
            coverage.append((0..<(88 * 72)).reduce(0) { $0 + Int(pixels[$1 * 4 + 3]) })
            frames.insert(Data(bytes: context.data!, count: 88 * 72 * 4))
        }
        expect(movingCycles.isSuperset(of: [0, 1, 2]), "Offline layers stopped moving after their first cycle")
        expect(frames.count > 5, "Offline animation did not produce changing rendered frames")
        expect(coverage.min()! < coverage.max()! / 4,
               "A stationary glyph remains beneath the replacement animation")

        icon.update(isOffline: true, reduceMotion: true)
        run(0.1)
        expect(parts().isEmpty, "Reduced Motion left offline animation running")
        let settled = snapshot(icon)
        run(0.15)
        expect(snapshot(icon) == settled, "Reduced Motion did not leave a stable icon")

        icon.update(isOffline: true, reduceMotion: false)
        expect(parts().count > 1, "Offline animation did not resume")
        icon.update(isOffline: false, reduceMotion: false)
        run(0.1)
        expect(parts().isEmpty, "Offline animation continued after reconnecting")
    }

    @MainActor private static func checkTint(_ icon: StatusIconView) {
        // Reuse the same view to catch colors frozen to the initial appearance.
        for appearance in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            icon.window!.appearance = NSAppearance(named: appearance)
            for (offline, reduceMotion) in [(false, true), (true, true), (true, false)] {
                icon.update(isOffline: offline, reduceMotion: reduceMotion)
                for emphasized in [false, true, false] {
                    icon.setEmphasized(emphasized)
                    var expected = NSColor.black
                    icon.effectiveAppearance.performAsCurrentDrawingAppearance {
                        expected = (emphasized ? NSColor.selectedMenuItemTextColor
                                    : NSColor.labelColor.withAlphaComponent(1)).usingColorSpace(.sRGB)!
                    }
                    let bitmap: NSBitmapImageRep
                    if reduceMotion {
                        bitmap = icon.bitmapImageRepForCachingDisplay(in: icon.bounds)!
                        icon.cacheDisplay(in: icon.bounds, to: bitmap)
                    } else {
                        let context = CGContext(data: nil, width: 44, height: 36, bitsPerComponent: 8,
                                                bytesPerRow: 44 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                        context.scaleBy(x: 2, y: 2)
                        icon.layer!.render(in: context)
                        bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
                    }
                    var grayPixels = 0
                    var primaryPixels = 0
                    for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                        let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                        guard color.alphaComponent > 0.99 else { continue }
                        func matches(_ target: NSColor) -> Bool {
                            abs(color.redComponent - target.redComponent) < 0.01 &&
                            abs(color.greenComponent - target.greenComponent) < 0.01 &&
                            abs(color.blueComponent - target.blueComponent) < 0.01
                        }
                        // AppKit may adapt palette gray for menu vibrancy; both
                        // native static rendering and animated masks must stay gray.
                        let gray = offline && color.redComponent > 0.25 && color.redComponent < 0.85 &&
                            abs(color.redComponent - color.greenComponent) < 0.03 &&
                            abs(color.redComponent - color.blueComponent) < 0.05
                        if gray { grayPixels += 1 }
                        if matches(expected) { primaryPixels += 1 }
                        expect(matches(expected) || gray,
                               "Status icon tint mismatch: \(appearance.rawValue), offline=\(offline), reduceMotion=\(reduceMotion), emphasized=\(emphasized), color=\(color), primary=\(expected)")
                    } }
                    if offline { expect(grayPixels > 0, "Offline rings lost their gray hierarchy: \(appearance.rawValue), reduceMotion=\(reduceMotion), emphasized=\(emphasized)") }
                    expect(primaryPixels > 0, "Status icon lost its primary foreground color")
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
