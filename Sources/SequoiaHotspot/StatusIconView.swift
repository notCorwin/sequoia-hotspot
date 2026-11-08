import AppKit
import QuartzCore

@MainActor final class StatusIconView: NSImageView {
    static let iconWidth: CGFloat = 22
    static let horizontalInset: CGFloat = 2

    private static let symbolStyle = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        .applying(.preferringMonochrome())
    private static let connectedImage = symbol("personalhotspot")
    private static let disconnectedImage = symbol("personalhotspot.slash", isTemplate: false)
    // labelColor includes translucency. Keep its appearance-dependent hue, but
    // draw solid menu-bar glyphs instead of blending them into the background.
    private static let normalTint = NSColor(name: nil) { appearance in
        var color = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.withAlphaComponent(1)
        }
        return color
    }

    private static func symbol(_ name: String, isTemplate: Bool = true) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(isTemplate ? symbolStyle
                : NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        image?.isTemplate = isTemplate
        return image
    }

    private var offline: Bool?
    private var replacementLayers: [CALayer] = []
    private var emphasized = false
    private static var layerMasks: [CGFloat: [CGImage]] = [:]

    func install(in button: NSStatusBarButton) {
        button.image = nil
        autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        button.addSubview(self)
        setEmphasized(false)
        setAccessibilityElement(false)
        alignWithButton()
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        alignWithButton()
    }

    private func alignWithButton() {
        guard let button = superview, let reference = Self.connectedImage else { return }
        let size = reference.alignmentRect.size
        let alignment = NSRect(x: button.bounds.midX - size.width / 2,
                               y: button.bounds.midY - size.height / 2,
                               width: size.width, height: size.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = frame(forAlignmentRect: alignment)
        CATransaction.commit()
    }

    func setEmphasized(_ emphasized: Bool) {
        self.emphasized = emphasized
        symbolConfiguration = Self.symbolStyle
        updateTint()
    }

    // Both symbols share a canvas center, regardless of their optical padding.
    override var alignmentRectInsets: NSEdgeInsets {
        var insets = super.alignmentRectInsets
        let vertical = (insets.top + insets.bottom) / 2
        insets.top = vertical
        insets.bottom = vertical
        return insets
    }

    // Keep the status button responsible for clicks and menu tracking.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(isOffline: Bool, reduceMotion: Bool) {
        if offline != isOffline {
            stopReplacement()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            image = isOffline ? Self.disconnectedImage : Self.connectedImage
            offline = isOffline
            updateTint()
            alignWithButton()
            CATransaction.commit()
        }

        guard isOffline && !reduceMotion else {
            stopReplacement()
            return
        }
        guard replacementLayers.isEmpty else { return }
        startReplacement()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard !replacementLayers.isEmpty else { return }
        stopReplacement()
        startReplacement()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for part in replacementLayers {
            part.frame = cell?.imageRect(forBounds: bounds) ?? bounds
            part.mask?.frame = part.bounds
        }
        CATransaction.commit()
    }

    private func updateTint() {
        cell?.backgroundStyle = emphasized && offline != true ? .emphasized : .normal
        let tint = emphasized ? NSColor.selectedMenuItemTextColor : Self.normalTint
        let rings = NSColor.systemGray
        if offline == true && replacementLayers.isEmpty {
            symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                .applying(.init(paletteColors: [tint, rings]))
            contentTintColor = nil
        } else {
            symbolConfiguration = Self.symbolStyle
            contentTintColor = replacementLayers.isEmpty ? tint : .clear
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (index, part) in replacementLayers.enumerated() {
                part.backgroundColor = (index == 0 ? rings : tint).cgColor
            }
            CATransaction.commit()
        }
    }

    private func startReplacement() {
        wantsLayer = true
        let scale = window?.backingScaleFactor ?? 2
        let masks = Self.masks(scale: scale)
        let start = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, image) in masks.enumerated() {
            let part = CALayer()
            part.frame = cell?.imageRect(forBounds: bounds) ?? bounds
            let mask = CALayer()
            mask.frame = part.bounds
            mask.contents = image
            mask.contentsScale = scale
            part.mask = mask
            layer!.addSublayer(part)
            replacementLayers.append(part)

            // Up-Up: grow the outgoing layer, then grow its replacement from small.
            // Preserve the half-speed motion, with no hold between replacements.
            let times: [NSNumber] = [0, 0.5, 0.503, 1]
            let size = CAKeyframeAnimation(keyPath: "transform.scale")
            size.keyTimes = times
            size.values = [1, 1.5, 0.5, 1]
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.keyTimes = times
            opacity.values = [1, 0, 0, 1]
            let easing = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            for animation in [size, opacity] {
                animation.duration = 0.56
                animation.timingFunctions = Array(repeating: easing, count: times.count - 1)
            }
            let replacement = CAAnimationGroup()
            replacement.animations = [size, opacity]
            replacement.duration = 0.56
            replacement.repeatCount = .infinity
            replacement.beginTime = start + Double(index) * 0.07
            replacement.fillMode = .backwards
            part.add(replacement, forKey: "offlineReplacement")
        }
        updateTint()
        CATransaction.commit()
    }

    private func stopReplacement() {
        guard !replacementLayers.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for part in replacementLayers { part.removeFromSuperlayer() }
        replacementLayers.removeAll()
        updateTint()
        CATransaction.commit()
    }

    // SF Symbols' palette supplies the native slash and chain masks. Cache only
    // scale-dependent geometry; appearance and menu highlighting change tint alone.
    private static func masks(scale: CGFloat) -> [CGImage] {
        if let cached = layerMasks[scale] { return cached }
        let palette = NSImage(systemSymbolName: "personalhotspot.slash", accessibilityDescription: nil)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                .applying(.init(paletteColors: [.red, .green])))!
        let width = Int(ceil(palette.size.width * scale))
        let height = Int(ceil(palette.size.height * scale))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: width * 4, bitsPerPixel: 32)!
        bitmap.size = palette.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        palette.draw(in: NSRect(origin: .zero, size: palette.size))
        NSGraphicsContext.restoreGraphicsState()
        let result = [1, 0].map { channel -> CGImage in
            let mask = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: width * 4, bitsPerPixel: 32)!
            for pixel in 0..<(width * height) {
                let alpha = bitmap.bitmapData![pixel * 4 + channel]
                for component in 0..<4 { mask.bitmapData![pixel * 4 + component] = alpha }
            }
            return mask.cgImage!
        }
        layerMasks[scale] = result
        return result
    }
}
