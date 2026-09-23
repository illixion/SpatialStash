/*
 Hypnos - AirPods head tracking for the film player (iOS, macOS)

 On visionOS RealityKit's audio listener is the wearer's head. On iOS and
 macOS it is the camera entity, and RealityKit doesn't follow AirPods head
 movement by itself (AirPods Max, iOS 27 and macOS 27: the sound field
 turned with the head). This reads the headphones' attitude through
 `CMHeadphoneMotionManager` and turns it into a listener orientation,
 relative to where the head pointed at start or at the last Recenter.

 Bluetooth adds latency after rendering (AirPods Max: tracking felt
 instant, the sound field settled late), so the orientation handed to the
 listener is predicted `predictionMs` ahead from the smoothed yaw and pitch
 rates. It defaults to the route's reported output latency less
 `predictionTrimMs`: with AirPods Max (171 ms reported on both iPhone and
 Mac) the full figure overshot slightly on sharp stops, and 20 ms less felt
 right.

 Axis mapping: yaw turns about RealityKit's +y (up), pitch about +x, roll
 about −z (the forward axis). Both frames are right-handed with positive
 angles counterclockwise, so yaw and pitch carry over with the same sign.

 The host needs NSMotionUsageDescription in its Info.plist.

 Moved from the app's Atmos spike (AtmosSpikeHeadTracker).
 */

#if os(iOS) || os(macOS)
import CoreMotion
import Observation
import simd

@MainActor
@Observable
public final class HeadphoneHeadTracker {
    public static let shared = HeadphoneHeadTracker()

    public private(set) var isTracking = false
    public private(set) var status = "Off"
    /// Relative head angles in degrees, for telemetry.
    public private(set) var yawDegrees: Double = 0
    public private(set) var pitchDegrees: Double = 0
    /// Listener orientation to apply to the camera entity.
    public private(set) var orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    /// How far ahead to predict the head, to cover output latency.
    public var predictionMs: Double = 0
    /// Output latency as the platform reports it for the current route.
    public private(set) var reportedLatencyMs: Double = 0

    @ObservationIgnored private let manager = CMHeadphoneMotionManager()
    @ObservationIgnored private var reference: CMAttitude?
    @ObservationIgnored private var yawRate: Double = 0
    @ObservationIgnored private var pitchRate: Double = 0
    @ObservationIgnored private var previous: (time: TimeInterval, yaw: Double, pitch: Double)?
    @ObservationIgnored private var predictionSet = false
    /// Taken off the reported latency; see the header.
    private let predictionTrimMs: Double = 20

    private init() {}

    public func start() {
        guard !isTracking else { return }
        guard manager.isDeviceMotionAvailable else {
            status = "Headphone motion unavailable"
            return
        }
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .denied, .restricted:
            status = "Motion access denied (System Settings → Privacy → Motion & Fitness)"
            return
        default:
            break
        }
        reference = nil
        previous = nil
        yawRate = 0
        pitchRate = 0
        refreshReportedLatency()
        if !predictionSet {
            useReportedLatency()
            predictionSet = true
        }
        isTracking = true
        status = "Waiting for headphones…"
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            MainActor.assumeIsolated {
                self?.update(motion: motion, error: error)
            }
        }
    }

    public func stop() {
        manager.stopDeviceMotionUpdates()
        isTracking = false
        reference = nil
        orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        status = "Off"
    }

    /// Makes the current head direction "facing the screen".
    public func recenter() {
        reference = nil
        previous = nil
    }

    /// Sets the prediction from the route's current latency.
    public func useReportedLatency() {
        refreshReportedLatency()
        predictionMs = max(0, reportedLatencyMs - predictionTrimMs).rounded()
    }

    public func refreshReportedLatency() {
        reportedLatencyMs = AudioOutputLatency.current() * 1000
    }

    private func update(motion: CMDeviceMotion?, error: Error?) {
        if let error {
            status = "Error: \(error.localizedDescription)"
            return
        }
        guard let motion else { return }
        guard let reference else {
            self.reference = motion.attitude.copy() as? CMAttitude
            return
        }
        let attitude = motion.attitude.copy() as! CMAttitude
        attitude.multiply(byInverseOf: reference)
        let yaw = attitude.yaw
        let pitch = attitude.pitch
        let roll = Float(attitude.roll)

        // Angular rates from successive samples, lightly smoothed; yaw wraps at ±π.
        if let previous, motion.timestamp > previous.time {
            let dt = motion.timestamp - previous.time
            let dYaw = remainder(yaw - previous.yaw, 2 * .pi)
            let alpha = 0.35
            yawRate += alpha * (dYaw / dt - yawRate)
            pitchRate += alpha * ((pitch - previous.pitch) / dt - pitchRate)
        }
        previous = (motion.timestamp, yaw, pitch)

        // Aim ahead, capped so a jerk can't swing the field wildly.
        let ahead = predictionMs / 1000
        let limit = Double.pi / 4
        let predictedYaw = yaw + max(-limit, min(yawRate * ahead, limit))
        let predictedPitch = pitch + max(-limit, min(pitchRate * ahead, limit))
        orientation = simd_quatf(angle: Float(predictedYaw), axis: [0, 1, 0])
            * simd_quatf(angle: Float(predictedPitch), axis: [1, 0, 0])
            * simd_quatf(angle: roll, axis: [0, 0, -1])
        yawDegrees = yaw * 180 / .pi
        pitchDegrees = pitch * 180 / .pi
        status = "Tracking"
    }
}
#endif
