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
                let mask = snapshot(button)
                if offline {
                    checkAlignment(online!, mask)
                    let frame = icon.frame
                    icon.update(isOffline: true, reduceMotion: true)
                    expect(icon.frame == frame, "Reduced Motion moved the icon")
                    icon.update(isOffline: true, reduceMotion: false)
                } else if let online {
                    expect(mask == online, "Returning from an active pulse changed the online icon")
                } else {
                    online = mask
                }
            }
            icon.removeFromSuperview()
            button.removeFromSuperview()
        }
        print("Status icon transitions keep the chain aligned at both menu-bar heights.")
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
