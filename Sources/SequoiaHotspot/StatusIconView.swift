import AppKit
import Symbols

@MainActor final class StatusIconView: NSImageView {
    static let iconSize = NSSize(width: 22, height: 18)
    static let horizontalInset: CGFloat = 2

    private static let symbolStyle = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        .applying(.preferringMonochrome())
    static let connectedImage: NSImage? = {
        let image = NSImage(systemSymbolName: "personalhotspot", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolStyle)
        image?.isTemplate = true
        return image
    }()

    private var isOffline: Bool?
    private var pulsing = false

    func setEmphasized(_ emphasized: Bool) {
        cell?.backgroundStyle = emphasized ? .emphasized : .normal
        symbolConfiguration = Self.symbolStyle
        contentTintColor = emphasized ? .selectedMenuItemTextColor : .labelColor
    }

    // Keep the status button responsible for clicks and menu tracking.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(isOffline: Bool, reduceMotion: Bool) {
        if self.isOffline != isOffline {
            self.isOffline = isOffline
            let image = isOffline
                ? NSImage(systemSymbolName: "personalhotspot.slash", accessibilityDescription: nil)
                : nil
            image?.isTemplate = true
            self.image = image
            if symbolConfiguration == nil { setEmphasized(false) }
            setAccessibilityElement(false)
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
