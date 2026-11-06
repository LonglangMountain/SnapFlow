import AppKit

/// Toolbar glyphs for the editor / capture bars.
///
/// The custom icons live as SVG files in `Resources/icons` and are copied into
/// the app bundle by `build.sh`. AppKit renders SVG natively (vector, any
/// size), so they can be loaded at runtime without a conversion step. Icons
/// that have no SVG yet (select, redo) fall back to SF Symbols.
enum IconLibrary {

    /// Glyph size in points. The SVG art is a 24×24 canvas whose ink only spans
    /// ~17pt of it, so drawing at 18pt made the strokes ~12pt — visibly smaller
    /// than the SF Symbols beside them. 26pt brings the ink to ~18.5pt.
    private static let glyphSize = NSSize(width: 26, height: 26)

    /// Optical-size fixes for individual icons: artwork with a lot of internal
    /// detail (long capture) reads smaller, while edge-to-edge art (OCR
    /// brackets) reads bigger — nudge each so the set looks even.
    ///
    /// SVG stroke-width scales with display size, so an icon listed here must
    /// carry a compensating stroke-width in its file: to render the same
    /// stroke as the 26pt base, use `1.6 * 26 / size`
    /// (ocr 24pt → 1.73, long 29pt → 1.43).
    private static let sizeOverrides: [String: CGFloat] = ["ocr": 24]

    /// Template (single-colour) icon, tinted by `contentTintColor` like the SF
    /// Symbols around it. Loads `Resources/icons/tool-<name>.svg`.
    static func toolbar(_ name: String, fallbackSymbol: String,
                        description: String? = nil) -> NSImage? {
        load(name, fallbackSymbol: fallbackSymbol, description: description, template: true)
    }

    /// SVG in its own colours (the red ✕ / green ✓ designs).
    static func toolbarColored(_ name: String, fallbackSymbol: String,
                               description: String? = nil) -> NSImage? {
        load(name, fallbackSymbol: fallbackSymbol, description: description, template: false)
    }

    private static func load(_ name: String, fallbackSymbol: String,
                             description: String?, template: Bool) -> NSImage? {
        if let url = Bundle.main.url(forResource: "tool-\(name)", withExtension: "svg",
                                     subdirectory: "icons"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = template
            let side = sizeOverrides[name] ?? glyphSize.width
            image.size = NSSize(width: side, height: side)
            return image
        }
        return NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: description)
    }
}
