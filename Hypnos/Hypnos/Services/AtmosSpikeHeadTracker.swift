/*
 Hypnos - Atmos Object Spike head tracking (iOS)

 On visionOS RealityKit's audio listener is the wearer's head. On iOS it is
 the camera entity, and RealityKit does not follow AirPods head movement by
 itself (measured with AirPods Max, iOS 27: the sound field turned with the
 head). This reads the headphones' attitude through
 `CMHeadphoneMotionManager` and turns it into a listener orientation, relative
 to where the head pointed at start or at the last Recenter.

 Axis mapping: yaw turns about RealityKit's +y (up), pitch about +x, roll
 about −z (the forward axis). Both frames are right-handed with positive
 angles counterclockwise, so yaw and pitch carry over with the same sign;
 if one is ever found inverted on device, `yawSign` is the place to flip it.
 */

#if os(iOS)
import CoreMotion
import Observation
import simd

@MainActor
@Observable
final class AtmosSpikeHeadTracker {
    static let shared = AtmosSpikeHeadTracker()

    private(set) var isTracking = false
    private(set) var status = "Off"
    /// Relative head angles in degrees, for the telemetry readout.
    private(set) var yawDegrees: Double = 0
    private(set) var pitchDegrees: Double = 0
    /// Listener orientation to apply to the camera entity.
    private(set) var orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    @ObservationIgnored private let manager = CMHeadphoneMotionManager()
    @ObservationIgnored private var reference: CMAttitude?
    @ObservationIgnored private let yawSign: Float = 1

    private init() {}

    func start() {
        guard !isTracking else { return }
        guard manager.isDeviceMotionAvailable else {
            status = "Headphone motion unavailable"
            return
        }
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .denied, .restricted:
            status = "Motion access denied (Settings → Privacy → Motion & Fitness)"
            return
        default:
            break
        }
        reference = nil
        isTracking = true
        status = "Waiting for headphones…"
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            MainActor.assumeIsolated {
                self?.update(motion: motion, error: error)
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        isTracking = false
        reference = nil
        orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        status = "Off"
    }

    /// Makes the current head direction "facing the screen".
    func recenter() {
        reference = nil
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
        let yaw = Float(attitude.yaw) * yawSign
        let pitch = Float(attitude.pitch)
        let roll = Float(attitude.roll)
        orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
            * simd_quatf(angle: pitch, axis: [1, 0, 0])
            * simd_quatf(angle: roll, axis: [0, 0, -1])
        yawDegrees = Double(yaw) * 180 / .pi
        pitchDegrees = Double(pitch) * 180 / .pi
        status = "Tracking"
    }
}
#endif
