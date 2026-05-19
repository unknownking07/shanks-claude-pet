import AppKit

// MARK: - Theme

enum PetTheme {
    static let shell = NSColor(red: 0.929, green: 0.647, blue: 0.235, alpha: 1.0)
    static let paper = NSColor(red: 0.980, green: 0.944, blue: 0.902, alpha: 1.0)
    static let milk  = NSColor(red: 0.996, green: 0.988, blue: 0.972, alpha: 1.0)
    static let blush = NSColor(red: 0.972, green: 0.820, blue: 0.760, alpha: 1.0)
    static let ink   = NSColor(red: 0.188, green: 0.156, blue: 0.141, alpha: 1.0)
    static let error = NSColor(red: 0.850, green: 0.250, blue: 0.200, alpha: 1.0)
    static let ok    = NSColor(red: 0.300, green: 0.650, blue: 0.400, alpha: 1.0)
}

// MARK: - Fonts

enum PetFonts {
    static func rounded(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static func mono(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}

// MARK: - Window

class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Extensions

extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
