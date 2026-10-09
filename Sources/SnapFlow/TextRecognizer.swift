import Vision

/// Recognizes text in a captured image using Apple's Vision framework.
/// Fully on-device — no network, no API key — matching SnapFlow's local,
/// privacy-friendly posture. Input is a `CGImage` (captured region or the
/// editor's flattened image).
enum TextRecognizer {

    /// Run accurate text recognition off the main thread and return the
    /// recognized lines in reading order (empty array if nothing is found).
    static func recognize(_ image: CGImage) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: recognizeSync(image))
            }
        }
    }

    // MARK: - Helpers

    private static func recognizeSync(_ image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        // Accurate level handles screenshot text (crisp screen pixels) well;
        // language correction fixes common misreads. Chinese + English cover
        // the typical SnapFlow use case.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("SnapFlow: OCR failed: \(error.localizedDescription)")
            return []
        }

        guard let observations = request.results else { return [] }
        return observations.compactMap { $0.topCandidates(1).first?.string }
    }
}
