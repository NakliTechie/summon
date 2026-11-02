import AppKit

extension NSScrollView {
    /// Make the document text view span the scroll view's content width. A text view
    /// left at width 0 lays its text out and draws nothing (seen live 2026-11-02 in
    /// the answer card), so each card sets the width on every layout instead of
    /// trusting autoresizing.
    func fitDocumentTextViewToWidth() {
        guard let text = documentView as? NSTextView else { return }
        let width = contentSize.width
        guard width > 0, text.frame.width != width else { return }
        text.setFrameSize(NSSize(width: width, height: max(text.frame.height, contentSize.height)))
        text.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }
}

extension NSView {
    /// Sampled pixels that differ clearly from the corner pixel: 0 means nothing is drawn.
    func inkedPixels() -> Int {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return -1 }
        cacheDisplay(in: bounds, to: rep)
        guard let corner = rep.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB) else { return -1 }
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let d = abs(c.redComponent - corner.redComponent) + abs(c.greenComponent - corner.greenComponent)
                    + abs(c.blueComponent - corner.blueComponent) + abs(c.alphaComponent - corner.alphaComponent)
                if d > 0.3 { count += 1 }
            }
        }
        return count
    }
}
