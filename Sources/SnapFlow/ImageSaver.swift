import AppKit

/// Persists a captured image to disk and places it on the clipboard.
/// Auto-copy is the default behavior per the design doc.
enum ImageSaver {

    /// Saves `image` as PNG under ~/Pictures/SnapFlow and returns the file URL.
    @discardableResult
    static func save(_ image: CGImage) -> URL? {
        guard let data = pngData(image) else { return nil }

        let fm = FileManager.default
        guard let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = pictures.appendingPathComponent("SnapFlow", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("SnapFlow-\(timestamp()).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            NSLog("SnapFlow: failed to write \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    /// Copies `image` to the general pasteboard as PNG (+ TIFF fallback).
    static func copyToClipboard(_ image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        if let png = rep.representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: .png)
        }
        if let tiff = rep.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    // MARK: - Background variants (long shots are huge; encoding blocks the UI)

    /// PNG-encode and write off the main thread.
    static func saveInBackground(_ image: CGImage) async -> URL? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: save(image))
            }
        }
    }

    /// Encode off the main thread, then set the pasteboard on the main thread.
    static func copyToClipboardInBackground(_ image: CGImage) async {
        let encoded: (png: Data?, tiff: Data?) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let rep = NSBitmapImageRep(cgImage: image)
                continuation.resume(returning: (rep.representation(using: .png, properties: [:]),
                                                rep.tiffRepresentation))
            }
        }
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.declareTypes([.png, .tiff], owner: nil)
            if let png = encoded.png { pasteboard.setData(png, forType: .png) }
            if let tiff = encoded.tiff { pasteboard.setData(tiff, forType: .tiff) }
        }
    }

    // MARK: - Helpers

    private static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
