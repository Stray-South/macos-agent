import Foundation
import ScreenCaptureKit
import Vision

public struct VisionCapture: Sendable {
    public let observations: [VisionObservation]
    /// True when Vision had to capture the entire display rather than just
    /// the frontmost app's windows. OCR may include text from background apps.
    public let usedFullScreenFallback: Bool
    /// Screen-point origin of the captured region's top-left corner.
    /// .zero for full-screen fallback. Window union rect origin for app-scoped captures.
    /// Used downstream by Executor to convert vision pixel coordinates to screen points.
    public let captureOrigin: CGPoint

    public init(observations: [VisionObservation], usedFullScreenFallback: Bool, captureOrigin: CGPoint = .zero) {
        self.observations = observations
        self.usedFullScreenFallback = usedFullScreenFallback
        self.captureOrigin = captureOrigin
    }
}

public protocol VisionPerceiving: Sendable {
    func captureVisualContext() async throws -> VisionCapture
}

public enum VisionPerceptionError: Error, LocalizedError, Sendable {
    case noDisplay

    public var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display is available for screen capture."
        }
    }
}

public struct VisionPerception: VisionPerceiving {
    public init() {}

    public func captureVisualContext() async throws -> VisionCapture {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw VisionPerceptionError.noDisplay
        }

        // Scope capture to the frontmost app's windows only so Vision doesn't
        // pick up text from background apps and confuse the LLM.
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let filter: SCContentFilter
        let usedFullScreenFallback: Bool
        // captureOrigin: screen-point top-left of the captured region.
        // Needed so Executor can convert vision pixel coords to screen points correctly.
        let captureOrigin: CGPoint
        // NSWorkspace.shared.frontmostApplication is @MainActor-isolated in
        // Swift 6's AppKit annotations. Snapshot the PID once on MainActor and
        // thread the value through; matches the dominant codebase pattern of
        // hopping for every @MainActor singleton read from an actor/struct
        // context.
        let frontPID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        if let frontPID,
           let scApp = content.applications.first(where: { $0.processID == frontPID }),
           !content.windows.filter({ $0.owningApplication?.processID == frontPID }).isEmpty {
            // Capture only the frontmost app's windows.
            let appWindows = content.windows.filter {
                $0.owningApplication?.processID == frontPID
            }
            // SCContentFilter with an empty array can crash or return a black frame on some
            // macOS releases. Windows can disappear between the outer isEmpty check and here.
            if !appWindows.isEmpty {
                filter = SCContentFilter(display: display, including: appWindows)
                usedFullScreenFallback = false
                _ = scApp  // silence unused warning
                // Compute bounding rect of all captured windows in screen points.
                let frames = appWindows.map(\.frame)
                if let first = frames.first {
                    let union = frames.dropFirst().reduce(first) { $0.union($1) }
                    captureOrigin = union.origin
                } else {
                    captureOrigin = .zero
                }
            } else {
                // Unit 6 — exclude the agent's own windows from the full-screen
                // fallback (same anti-pattern that Unit 5 closed for AX and
                // Unit 6 closed for the CU primary capture path). Without
                // this, Vision OCR reads text from the agent's HUD/launcher
                // overlay and feeds it back into the LLM context. See
                // Support/AgentIdentity.swift for the shared helper.
                filter = SCContentFilter(display: display, excludingApplications: agentAppsToExclude(in: content.applications), exceptingWindows: [])
                usedFullScreenFallback = true
                captureOrigin = .zero
            }
        } else {
            // Fallback: full display capture if we can't isolate the app.
            // Unit 6 follow-up: this OUTER else-branch is the third full-screen
            // fallback path (first two patched at lines 73, 85). It fires when
            // frontPID is nil OR no SCApp matches frontPID OR no windows for
            // that PID. Same anti-pattern, same fix — exclude the agent so
            // Vision OCR doesn't read the launcher's overlay text.
            filter = SCContentFilter(display: display, excludingApplications: agentAppsToExclude(in: content.applications), exceptingWindows: [])
            usedFullScreenFallback = true
            // Full-screen capture starts at screen origin.
            captureOrigin = .zero
        }

        // Retry up to 3 times with exponential backoff to handle transient
        // ScreenCaptureKit failures (e.g. momentary screen lock, display sleep).
        var cgImage: CGImage?
        var lastError: Error?
        for attempt in 1...3 {
            do {
                cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                break
            } catch {
                lastError = error
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 100_000_000) // 0.1s, 0.2s
                }
            }
        }
        guard let cgImage else {
            throw lastError ?? VisionPerceptionError.noDisplay
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try handler.perform([request])

        let width = cgImage.width
        let height = cgImage.height
        let observations: [VisionObservation] = (request.results ?? []).compactMap { observation in
            guard let topCandidate = observation.topCandidates(1).first else { return nil }
            // Vision bounding boxes use bottom-left origin; convert to top-left origin.
            let pixelX = observation.boundingBox.minX * Double(width)
            let pixelY = (1.0 - observation.boundingBox.maxY) * Double(height)
            let pixelW = observation.boundingBox.width * Double(width)
            let pixelH = observation.boundingBox.height * Double(height)
            let rect = CGRect(x: pixelX, y: pixelY, width: pixelW, height: pixelH)
            return VisionObservation(text: topCandidate.string, boundingBox: CodableRect(rect))
        }
        return VisionCapture(observations: observations, usedFullScreenFallback: usedFullScreenFallback, captureOrigin: captureOrigin)
    }
}
