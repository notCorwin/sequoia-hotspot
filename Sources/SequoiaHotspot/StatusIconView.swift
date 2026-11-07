import AppKit
import Symbols

@MainActor final class StatusIconView: NSImageView {
    static let iconWidth: CGFloat = 22
    static let horizontalInset: CGFloat = 2

    private static let symbolStyle = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        .applying(.preferringMonochrome())
    static let connectedImage: NSImage? = {
        let image = NSImage(systemSymbolName: "personalhotspot", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolStyle)
        image?.isTemplate = true
        return image
    }()

    private var pulsing = false
    private var alignmentCell: NSButtonCell?

    func install(in button: NSStatusBarButton) {
        alignmentCell = button.cell?.copy() as? NSButtonCell
        alignmentCell?.image = Self.connectedImage
        alignmentCell?.imagePosition = .imageOnly
        alignmentCell?.controlView = button
        autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        button.addSubview(self)
        alignWithButton()
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        alignWithButton()
    }

    private func alignWithButton() {
        guard let button = superview as? NSStatusBarButton, let alignmentCell else { return }
        // Keep native image geometry even while the button's own image is hidden.
        frame = frame(forAlignmentRect: alignmentCell.imageRect(forBounds: button.bounds))
    }

    func setEmphasized(_ emphasized: Bool) {
        cell?.backgroundStyle = emphasized ? .emphasized : .normal
        symbolConfiguration = Self.symbolStyle
        contentTintColor = emphasized ? .selectedMenuItemTextColor : .labelColor
    }

    // Keep the status button responsible for clicks and menu tracking.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(isOffline: Bool, reduceMotion: Bool) {
        if image == nil {
            let image = NSImage(systemSymbolName: "personalhotspot.slash", accessibilityDescription: nil)?
                .withSymbolConfiguration(Self.symbolStyle)
            image?.isTemplate = true
            self.image = image
            if symbolConfiguration == nil { setEmphasized(false) }
            setAccessibilityElement(false)
            alignWithButton()
        }

        let shouldPulse = isOffline && !reduceMotion
        guard pulsing != shouldPulse else { return }
        pulsing = shouldPulse
        if shouldPulse {
            addSymbolEffect(.pulse.byLayer, options: .repeat(.continuous).speed(4))
        } else {
            removeAllSymbolEffects(animated: false)
        }
    }
}
