import AVFoundation
import AppKit
import Combine
import SwiftGodot
import SwiftGodotKit
import Vision

/// Front-camera face tracker for body-pose games previewed on macOS.
///
/// Mirrors the iPhone `FaceDetector`'s contract on the macOS host: when
/// the user has the toolbar control-mode picker set to `body_pose`, we
/// open the built-in front camera, run Vision face detection at 30 Hz,
/// and write the same `/root/InputBridge` properties the iPhone writes
/// (`face_position`, `face_detected`, `body_lean_x/y`, `body_detected`).
/// `MacOSInputAdapter` continues to drive everything else (hand
/// gesture, tap-like buttons), but it consults `MacFaceDetector.isActive`
/// and skips the four face/body fields so the two adapters don't fight.
///
/// The session boots lazily on the first `start()` call so users who
/// never preview a body-pose game never see the camera permission
/// prompt. `stop()` tears the session down completely — Vision plus
/// AVCapture hold non-trivial resources we shouldn't keep alive while
/// the user is just typing in the terminal.
@MainActor
final class MacFaceDetector: ObservableObject {

    static let shared = MacFaceDetector()

    /// True while the AVCaptureSession is running. `MacOSInputAdapter`
    /// reads this every pump to decide whether to clobber face fields.
    @Published private(set) var isActive: Bool = false

    /// Last published face position in normalised viewport coordinates
    /// (0,0)=top-left, (1,1)=bottom-right. iOS contract — keep parity.
    @Published private(set) var lastFacePosition: CGPoint = CGPoint(x: 0.5, y: 0.5)

    private let session = AVCaptureSession()
    private let sampleQueue = DispatchQueue(label: "com.motem.facedetector.frames")
    private var output: AVCaptureVideoDataOutput?
    private weak var cachedBridge: SwiftGodot.Node?

    // Throttle face detection to ~30 Hz regardless of camera FPS. Vision
    // is happy to run faster but the bridge writes are the cost — the
    // host engine runs at 60 Hz max anyway. `lastPublishTime` lives on
    // `sampleQueue` only — the frame callback already serializes there,
    // and reading/writing from there avoids any cross-actor hop.
    private static let publishInterval: TimeInterval = 1.0 / 30.0
    nonisolated(unsafe) private var lastPublishTimeOnSampleQueue: TimeInterval = 0

    // Frame-receiver delegate adapter. Defined inline so the detector
    // class can stay `@MainActor` without forcing the AVCapture frame
    // callback to hop actors before our Vision work runs.
    private lazy var frameDelegate: FrameDelegate = FrameDelegate(owner: self)

    private init() {}

    // MARK: - Public

    /// Bring the camera up. Idempotent. Triggers the macOS camera
    /// permission prompt on first call ever.
    func start() {
        guard !isActive else { return }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    NSLog("[MacFaceDetector] camera access denied; body-pose game will use kbm fallback")
                    return
                }
                self.bootSession()
            }
        }
    }

    /// Tear the session down. Idempotent.
    func stop() {
        guard isActive else { return }
        session.stopRunning()
        if let output {
            session.removeOutput(output)
            self.output = nil
        }
        for input in session.inputs {
            session.removeInput(input)
        }
        isActive = false
        cachedBridge = nil
        // Tell the game the player is gone so any "lost face" handlers
        // (default skeleton hides the cursor / pauses, etc.) trigger.
        runOnGodotThread { bridge in
            bridge.set(property: "face_detected", value: Variant(false))
            bridge.set(property: "body_detected", value: Variant(false))
        }
    }

    /// Forget the cached InputBridge node. Call after `godot_reload`
    /// swaps the loaded_game subtree — the previous bridge node is
    /// orphaned and our weak reference would be nil anyway, but
    /// clearing it eagerly avoids one frame of "no writes" on switch.
    func invalidateBridgeCache() {
        cachedBridge = nil
    }

    // MARK: - Session boot

    private func bootSession() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video) else {
            NSLog("[MacFaceDetector] no front camera found on this Mac")
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .vga640x480  // 640×480 is plenty for Vision face rects

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            NSLog("[MacFaceDetector] failed to create AVCaptureDeviceInput: \(error)")
            session.commitConfiguration()
            return
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        output.setSampleBufferDelegate(frameDelegate, queue: sampleQueue)
        if session.canAddOutput(output) {
            session.addOutput(output)
            self.output = output
        }

        session.commitConfiguration()
        sampleQueue.async { [weak self] in
            self?.session.startRunning()
        }
        isActive = true
    }

    // MARK: - Vision pipeline (called from sampleQueue)

    /// Called on `sampleQueue` (background) every camera frame. Heavy
    /// Vision work stays off the main thread; only the final bridge
    /// write hops back to main.
    fileprivate nonisolated func handleFrame(_ pixelBuffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        if now - lastPublishTimeOnSampleQueue < Self.publishInterval { return }
        lastPublishTimeOnSampleQueue = now

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            // FaceTime camera ships frames in landscape-native orientation
            // (no rotation); the preview is mirrored left↔right so a
            // selfie-view matches the user's real movement. `upMirrored`
            // is the orientation that keeps Vision's X/Y axes aligned
            // with the user's horizontal/vertical head motion — anything
            // else (`.left`/`.right`) treats X as Y and swaps the axes.
            orientation: .upMirrored,
            options: [:]
        )
        let request = VNDetectFaceRectanglesRequest()
        do {
            try handler.perform([request])
        } catch {
            return
        }

        let detected: Bool
        let normX: Double
        let normY: Double
        if let face = (request.results ?? []).first {
            // Vision returns bounding box in normalised coordinates;
            // Godot's `face_position` contract is (0,0)=top-left,
            // (1,1)=bottom-right, matching iOS FaceDetector. Empirically
            // (verified against the macOS preview) the raw Vision Y
            // already aligns with that convention for the upMirrored
            // orientation, so no extra flip is needed.
            detected = true
            normX = Double(face.boundingBox.midX)
            normY = Double(face.boundingBox.midY)
        } else {
            detected = false
            normX = 0.5
            normY = 0.5
        }

        Task { @MainActor [weak self] in
            self?.publish(faceDetected: detected, normX: CGFloat(normX), normY: CGFloat(normY))
        }
    }

    // MARK: - Publishing (main-actor)

    private func publish(faceDetected: Bool, normX: CGFloat, normY: CGFloat) {
        lastFacePosition = CGPoint(x: normX, y: normY)
        // body_lean_x / body_lean_y are -1..1 deltas from screen center.
        // For face-only tracking, treat horizontal/vertical offset of
        // the face center as the lean — coarse but matches how v2
        // archetypes use `get_body_target(margin)` (which lerps anyway).
        let leanX = max(-1.0, min(1.0, (normX - 0.5) * 2.0))
        let leanY = max(-1.0, min(1.0, (normY - 0.5) * 2.0))

        runOnGodotThread { bridge in
            bridge.set(property: "face_position", value: Variant(Vector2(x: Float(normX), y: Float(normY))))
            bridge.set(property: "face_detected", value: Variant(faceDetected))
            bridge.set(property: "body_lean_x", value: Variant(Float(leanX)))
            bridge.set(property: "body_lean_y", value: Variant(Float(leanY)))
            bridge.set(property: "body_detected", value: Variant(faceDetected))
        }
    }

    // MARK: - Godot bridge

    private func runOnGodotThread(_ writes: @escaping (SwiftGodot.Node) -> Void) {
        guard let app = GodotPreviewController.shared.godotApp else { return }
        app.runOnGodotThread {
            MainActor.assumeIsolated {
                if let cached = self.cachedBridge {
                    writes(cached)
                } else if let found = MacOSInputAdapter.locateInputBridge() {
                    self.cachedBridge = found
                    writes(found)
                }
            }
        }
    }
}

// Separate ObjC-conforming delegate so MacFaceDetector itself can stay
// `@MainActor`. The frame callback fires on `sampleQueue` (background),
// hands the pixel buffer back into the detector's nonisolated entry
// point, which is the only thing AVCapture is allowed to invoke.
private final class FrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var owner: MacFaceDetector?

    init(owner: MacFaceDetector) {
        self.owner = owner
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let owner else { return }
        owner.handleFrame(pixelBuffer)
    }
}
