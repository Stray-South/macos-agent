/// ScreenScalerTests.swift
///
/// Pure-math tests for ComputerUseClient's screenshot downsampling + coordinate
/// rescaling. Tests are SCK-free — they construct synthetic CGImages via
/// CGContext and exercise the scaling math directly. No display required.
import CoreGraphics
@testable import MacAgentCore
import Testing

private func makeImage(width: Int, height: Int) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

@Test
func scaleDownIfNeeded_smallerThanMaxEdge_returnsUnchangedSize() {
    let img = makeImage(width: 1440, height: 900)
    let (out, size) = ScreenScaler.scaleDownIfNeeded(img, maxEdge: 1568)
    #expect(size == CGSize(width: 1440, height: 900))
    #expect(out.width == 1440 && out.height == 900)
}

@Test
func scaleDownIfNeeded_largerThanMaxEdge_scalesPreservingAspect() {
    let img = makeImage(width: 3200, height: 1800)
    let (out, size) = ScreenScaler.scaleDownIfNeeded(img, maxEdge: 1568)
    // long edge is 3200 → scale 1568/3200 = 0.49 → width = 1568, height = floor(1800*0.49) = 882
    #expect(size.width == 1568)
    #expect(size.height == 882)
    #expect(out.width == 1568 && out.height == 882)
}

@Test
func scaleDownIfNeeded_portraitLargerThanMaxEdge_scalesPreservingAspect() {
    let img = makeImage(width: 1800, height: 3200)
    let (_, size) = ScreenScaler.scaleDownIfNeeded(img, maxEdge: 1568)
    // long edge is 3200 → scale 0.49 → height = 1568, width = floor(1800*0.49) = 882
    #expect(size.height == 1568)
    #expect(size.width == 882)
}

@Test
func scaleDownIfNeeded_squareImage_scalesBothEdges() {
    let img = makeImage(width: 2000, height: 2000)
    let (_, size) = ScreenScaler.scaleDownIfNeeded(img, maxEdge: 1568)
    #expect(size.width == 1568)
    #expect(size.height == 1568)
}

@Test
func scaleDownIfNeeded_exactlyMaxEdge_returnsUnchanged() {
    let img = makeImage(width: 1568, height: 900)
    let (_, size) = ScreenScaler.scaleDownIfNeeded(img, maxEdge: 1568)
    #expect(size == CGSize(width: 1568, height: 900))
}

@Test
func descale_identityWhenSentSizeEqualsLogicalSize() {
    let p = ScreenScaler.descale(CGPoint(x: 500, y: 300),
                                  sentSize: CGSize(width: 1440, height: 900),
                                  logicalSize: CGSize(width: 1440, height: 900))
    #expect(p == CGPoint(x: 500, y: 300))
}

@Test
func descale_scalesUpProportionally() {
    // Logical screen 3024×1890, scaled-and-sent image 1568×980.
    // Claude reports a click at (784, 490) in the sent space.
    // Expected logical point: (784 * 3024/1568, 490 * 3024/1568) ≈ (1512, 945).
    let p = ScreenScaler.descale(CGPoint(x: 784, y: 490),
                                  sentSize: CGSize(width: 1568, height: 980),
                                  logicalSize: CGSize(width: 3024, height: 1890))
    #expect(abs(p.x - 1512) < 0.5)
    #expect(abs(p.y - 945) < 0.5)
}

@Test
func descale_inverseOfScaleDown_roundTripsCleanly() {
    // Generate a coord in logical space, project to sent space, descale back.
    // The error should be sub-pixel.
    let logical = CGSize(width: 3024, height: 1890)
    let img = makeImage(width: Int(logical.width), height: Int(logical.height))
    let (_, sentSize) = ScreenScaler.scaleDownIfNeeded(img, maxEdge: 1568)
    let scale = sentSize.width / logical.width
    // Coord Claude would report (in sent space) for a logical point at (1500, 940).
    let claudeReported = CGPoint(x: 1500 * scale, y: 940 * scale)
    let restored = ScreenScaler.descale(claudeReported, sentSize: sentSize, logicalSize: logical)
    #expect(abs(restored.x - 1500) < 1.0)
    #expect(abs(restored.y - 940) < 1.0)
}

@Test
func descale_zeroSentSize_returnsInputUnchanged() {
    // Defensive: if sentSize is somehow zero (e.g., capture failed), descale
    // must not divide-by-zero. Returns the input point untouched.
    let p = ScreenScaler.descale(CGPoint(x: 100, y: 100),
                                  sentSize: .zero,
                                  logicalSize: CGSize(width: 1440, height: 900))
    #expect(p == CGPoint(x: 100, y: 100))
}
