/// ScreenScaler.swift
///
/// Pure-math screenshot-resize + coordinate-rescale helpers for ComputerUseClient.
///
/// Why this exists: per Anthropic CU docs (computer-use-2025-11-24), only
/// `claude-opus-4-7` accepts up to 2576-px long-edge images and returns coords
/// 1:1 with image pixels. All other supported models (Opus 4.6, Sonnet 4.6,
/// Opus 4.5) operate in a 1568-px / 1.15-MP server-side downsampled space and
/// return coords in that scaled space. Without client-side downsample +
/// inverse scale-up, the cursor lands at the wrong screen point.
///
/// Reference: Anthropic's quickstart `computer-use-demo/tools/computer.py`
/// uses the same pre-scale + inverse-rescale pattern (with conservative
/// targets like XGA/WXGA/FWXGA below the 1568 cap).
import CoreGraphics

public enum ScreenScaler {
    /// The 1568-px cap applies to non-Opus-4.7 models per Anthropic CU docs.
    /// Constant exposed for tunability if Anthropic changes the cap.
    public static let cuMaxEdgeForScaledModels: CGFloat = 1568

    /// If `image` has a long edge > `maxEdge`, returns a downsampled copy with
    /// the long edge equal to `maxEdge` and the short edge scaled
    /// proportionally (integer pixels). Aspect ratio is preserved exactly.
    /// If already ≤ maxEdge, returns the input unchanged (size unchanged).
    /// The exact (non-rounded) scale factor — `image dim / scaled dim` —
    /// is recoverable as `(originalSize / scaledSize)` for inverse use.
    public static func scaleDownIfNeeded(_ image: CGImage, maxEdge: CGFloat) -> (CGImage, CGSize) {
        let originalWidth = CGFloat(image.width)
        let originalHeight = CGFloat(image.height)
        let longEdge = max(originalWidth, originalHeight)
        if longEdge <= maxEdge {
            return (image, CGSize(width: originalWidth, height: originalHeight))
        }
        let scale = maxEdge / longEdge
        // Use floor() so the long edge is exactly maxEdge or rounds down — never
        // exceeds. Cast back to integer pixel dims for the bitmap context.
        let scaledWidth = Int((originalWidth * scale).rounded(.down))
        let scaledHeight = Int((originalHeight * scale).rounded(.down))
        guard scaledWidth > 0, scaledHeight > 0 else {
            return (image, CGSize(width: originalWidth, height: originalHeight))
        }
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: scaledWidth,
            height: scaledHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (image, CGSize(width: originalWidth, height: originalHeight))
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
        guard let scaled = ctx.makeImage() else {
            return (image, CGSize(width: originalWidth, height: originalHeight))
        }
        return (scaled, CGSize(width: scaledWidth, height: scaledHeight))
    }

    /// Convert a coordinate Claude reports against `sentSize` (the dimensions
    /// of the image we sent) back to the original `logicalSize` (the real
    /// screen-points coordinate space the Executor posts events into).
    /// Aspect ratio is preserved by `scaleDownIfNeeded`, so x and y scale by
    /// the same factor — we compute it from width to avoid divergent rounding.
    public static func descale(_ point: CGPoint, sentSize: CGSize, logicalSize: CGSize) -> CGPoint {
        guard sentSize.width > 0, sentSize.height > 0 else { return point }
        let scale = logicalSize.width / sentSize.width
        return CGPoint(x: point.x * scale, y: point.y * scale)
    }
}
