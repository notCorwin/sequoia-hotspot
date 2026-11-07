import AppKit
import Symbols

@MainActor final class StatusIconView: NSImageView {
    static let iconSize = NSSize(width: 22, height: 18)
    static let horizontalInset: CGFloat = 3

    private var isOffline: Bool?
    private var breathing = false

    func setEmphasized(_ emphasized: Bool) {
        cell?.backgroundStyle = emphasized ? .emphasized : .normal
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(.init(hierarchicalColor: emphasized ? .selectedMenuItemTextColor : .labelColor))
    }

    // Keep the status button responsible for clicks and menu tracking.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(isOffline: Bool, reduceMotion: Bool) {
        if self.isOffline != isOffline {
            self.isOffline = isOffline
            let image = NSImage(systemSymbolName: isOffline ? "personalhotspot.slash" : "personalhotspot",
                                accessibilityDescription: nil)
            image?.isTemplate = true
            self.image = image
            if symbolConfiguration == nil { setEmphasized(false) }
            setAccessibilityElement(false)
        }

        let shouldBreathe = isOffline && !reduceMotion
        guard breathing != shouldBreathe else { return }
        breathing = shouldBreathe
        if shouldBreathe {
            addSymbolEffect(.breathe.pulse.byLayer, options: .repeat(.continuous))
        } else {
            removeAllSymbolEffects(animated: false)
        }
    }
}
