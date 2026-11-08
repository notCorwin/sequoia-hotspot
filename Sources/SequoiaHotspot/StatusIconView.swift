import AppKit
import QuartzCore
import Symbols

@MainActor final class StatusIconView: NSImageView {
    static let iconWidth: CGFloat = 22
    static let horizontalInset: CGFloat = 2

    private static let symbolStyle = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        .applying(.preferringMonochrome())
    private static let connectedImage = symbol("personalhotspot")
    private static let disconnectedImage = symbol("personalhotspot.slash")
    // labelColor includes translucency. Keep its appearance-dependent hue, but
    // draw solid menu-bar glyphs instead of blending them into the background.
    private static let normalTint = NSColor(name: nil) { appearance in
        var color = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.withAlphaComponent(1)
        }
        return color
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolStyle)
        image?.isTemplate = true
        return image
    }

    private var offline: Bool?
    private var replacing = false

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
        cell?.backgroundStyle = emphasized ? .emphasized : .normal
        symbolConfiguration = Self.symbolStyle
        contentTintColor = emphasized ? .selectedMenuItemTextColor : Self.normalTint
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if offline != isOffline {
            removeAllSymbolEffects(animated: false)
            replacing = false
            image = isOffline ? Self.disconnectedImage : Self.connectedImage
            offline = isOffline
            alignWithButton()
        }

        let shouldReplace = isOffline && !reduceMotion
        guard replacing != shouldReplace else { return }
        replacing = shouldReplace
        if shouldReplace, let image = Self.disconnectedImage {
            setSymbolImage(image, contentTransition: .replace.upUp.byLayer,
                           options: .repeat(.continuous).speed(4))
        } else {
            removeAllSymbolEffects(animated: false)
        }
    }
}
