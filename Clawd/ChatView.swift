import AppKit

final class PreviewCardView: NSView {
    var onTap: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = PetTheme.paper.cgColor
        layer?.cornerRadius = 14
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.08).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) { onTap?() }
}
