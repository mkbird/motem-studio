import AVFoundation
import AppKit
import Combine
import SwiftGodot
import SwiftGodotKit
import Vision

/// Front-camera face tracker for body-pose games previewed on macOS.
///
/// Mirrors the iPhone `FaceDetector`'s contract on the macOS host: when
/// the loaded game's `input_mode` (meta.json) is `body_pose`, we
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

    /// True once the camera has published at least one Vision frame to
    /// the InputBridge. Goes back to `false` whenever `stop()` runs.
    /// `GodotPreviewPane` watches this to show a brief "正在启动相机…"
    /// overlay during the AVCaptureSession spin-up so the player isn't
    /// staring at an unresponsive game while the camera boots.
    @Published private(set) var isReady: Bool = false

    /// Last published face position in normalised viewport coordinates
    /// (0,0)=top-left, (1,1)=bottom-right. iOS contract — keep parity.
    @Published private(set) var lastFacePosition: CGPoint = CGPoint(x: 0.5, y: 0.5)

    // Lazy so simply touching `MacFaceDetector.shared` from a SwiftUI
    // view body doesn't allocate an AVCaptureSession before Godot has
    // finished its first-time Metal / embedded-display-server init.
    // Eager allocation here SIGABRTs the engine in `Main::setup2()`.
    private lazy var session: AVCaptureSession = AVCaptureSession()
    private let sampleQueue = DispatchQueue(label: "com.motem.facedetector.frames")
    private var output: AVCaptureVideoDataOutput?
    private weak var cachedBridge: SwiftGodot.Node?

    /// Set while an `AVCaptureDevice.requestAccess` callback is still
    /// pending. `start()` can be called several times in rapid
    /// succession (game load + first state transition + ControlMode
    /// changes all fire `syncCamera()`), and without this guard each
    /// call queues another `bootSession()` on the main runloop; two
    /// `bootSession()` invocations racing on the same `AVCaptureSession`
    /// throw an NSException out of `commitConfiguration` /
    /// `startRunning` and SIGABRT the process.
    private var bootInFlight: Bool = false

    /// Periodic poller that mirrors `bridge.gameplay_active` into
    /// camera on/off. Installed by `startWatching()`, torn down by
    /// `stopWatching()`.
    private var watchTimer: Foundation.Timer?

    // Throttle face detection to ~30 Hz regardless of camera FPS. Vision
    // is happy to run faster but the bridge writes are the cost — the
    // host engine runs at 60 Hz max anyway. `lastPublishTime` lives on
    // `sampleQueue` only — the frame callback already serializes there,
    // and reading/writing from there avoids any cross-actor hop.
    private static let publishInterval: TimeInterval = 1.0 / 30.0
    nonisolated(unsafe) private var lastPublishTimeOnSampleQueue: TimeInterval = 0

    // Gain applied around the 0.5 centre when mapping Vision's
    // `boundingBox.midX/midY` to the InputBridge contract. A head that
    // is centred in front of a FaceTime camera typically only moves
    // through ~0.35–0.65 in normalised coordinates before falling off
    // the frame, so without amplification players can never push
    // `face_position` (and the derived `body_lean_*`) to the ±1 edges
    // that v2 archetypes use. 2.8 maps ~0.32→0 and ~0.68→1, which
    // matches the "lean your head" feel of the iPhone build.
    private static let faceCenterGain: Double = 2.8

    // Frame-receiver delegate adapter. Defined inline so the detector
    // class can stay `@MainActor` without forcing the AVCapture frame
    // callback to hop actors before our Vision work runs.
    private lazy var frameDelegate: FrameDelegate = FrameDelegate(owner: self)

    private init() {}

    // MARK: - Public

    /// Start polling the loaded game's `bridge.gameplay_active`. The
    /// camera comes up the instant the skeleton flips that flag in
    /// `_enter_playing` and is released the instant `_enter_game_over`
    /// (or pause / stop / mode-change) clears it. Pre-warming on game
    /// load was tried first but the user wanted strict "camera on iff
    /// player is actively playing" — the LED on the START screen of
    /// every body-pose game was too noisy.
    func startWatching() {
        guard watchTimer == nil else { return }
        // 250 ms is fast enough that the camera comes up within one
        // frame's worth of perceptible latency after the player taps
        // "tap to start", and slow enough to keep the polling cost
        // negligible.
        watchTimer = Foundation.Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcileWithGameState() }
        }
        // Reconcile immediately so the first tick doesn't cost 250 ms.
        reconcileWithGameState()
    }

    /// Force the camera off + stop polling. Called when the user flips
    /// back to `touch`, unloads the previewed game, or pauses the
    /// preview pane.
    func stopWatching() {
        watchTimer?.invalidate()
        watchTimer = nil
        stop()
    }

    /// Bring the camera up if it isn't already. Triggers the macOS
    /// camera permission prompt on first call ever. Public only for
    /// `reconcileWithGameState` — external callers should drive
    /// lifecycle through `startWatching` / `stopWatching`.
    fileprivate func start() {
        guard !isActive, !bootInFlight else { return }
        bootInFlight = true
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.bootInFlight = false
                // Re-check on the main runloop — `stop()` may have run
                // between the request and the callback (user paused
                // the preview), and a second `start()` may have raced
                // ahead and already booted the session.
                guard granted else {
                    NSLog("[MacFaceDetector] camera access denied; body-pose game will use kbm fallback")
                    return
                }
                guard !self.isActive else { return }
                self.bootSession()
            }
        }
    }

    /// Tear the session down. Idempotent.
    fileprivate func stop() {
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
        isReady = false
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

    /// Poll the live `bridge.gameplay_active` flag and bring the
    /// camera in line with it. The migrated skeleton sets the flag
    /// true on `_enter_playing` and false on `_enter_game_over`, so
    /// the camera is only powered while the player is actively
    /// playing — START screens, GAME OVER screens and host-pause all
    /// release it. Runs every 250 ms while `startWatching()` is in
    /// effect.
    private func reconcileWithGameState() {
        guard let app = GodotPreviewController.shared.godotApp else {
            if isActive { stop() }
            return
        }
        // Host pause short-circuits everything else.
        if GodotPreviewController.shared.paused {
            if isActive { stop() }
            return
        }
        app.runOnGodotThread {
            MainActor.assumeIsolated {
                let bridge = self.cachedBridge ?? MacOSInputAdapter.locateInputBridge()
                self.cachedBridge = bridge
                let wantsCamera = bridge?.get(property: "gameplay_active").to(Bool.self) ?? false
                if wantsCamera && !self.isActive {
                    self.start()
                } else if !wantsCamera && self.isActive {
                    self.stop()
                }
            }
        }
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
        // First Vision result back means the AVCaptureSession is actually
        // pumping pixels — flip `isReady` so `GodotPreviewPane` can drop
        // its "camera warming up" overlay and let gameplay take input.
        if !isReady { isReady = true }
        lastFacePosition = CGPoint(x: normX, y: normY)
        // Vision's face midpoint only sweeps a narrow band around 0.5
        // even when the player moves their head fully across the camera
        // frame; amplify around the 0.5 centre so reasonable head
        // motion can push `face_position` and `body_lean_*` to the
        // edges games actually care about. Clamp to the InputBridge
        // contract afterwards.
        let gain = Self.faceCenterGain
        let amplifiedX = max(0.0, min(1.0, (Double(normX) - 0.5) * gain + 0.5))
        let amplifiedY = max(0.0, min(1.0, (Double(normY) - 0.5) * gain + 0.5))
        // body_lean_x / body_lean_y are -1..1 deltas from screen center.
        let leanX = max(-1.0, min(1.0, (amplifiedX - 0.5) * 2.0))
        let leanY = max(-1.0, min(1.0, (amplifiedY - 0.5) * 2.0))

        runOnGodotThread { bridge in
            bridge.set(property: "face_position", value: Variant(Vector2(x: Float(amplifiedX), y: Float(amplifiedY))))
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
