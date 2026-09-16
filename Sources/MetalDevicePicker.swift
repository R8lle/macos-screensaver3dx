import Foundation
import Metal

/// Metal device selection for dual-GPU Macs (Intel UHD + AMD Radeon, etc.).
///
/// Under Automatic graphics switching, `MTLCreateSystemDefaultDevice()` often
/// returns the integrated (low-power) GPU while the discrete GPU is still
/// powered down or mid-switch. Starting Metal on iGPU then yields a lasting
/// black screensaver. Prefer the discrete device and briefly warm it so the
/// switch has somewhere to land before the first real frame.
enum MetalDevicePicker {
    static func preferred(log: ((String) -> Void)? = nil) -> MTLDevice? {
        preferredReady(timeoutSeconds: 0, log: log)
    }

    /// Same search/warm-up as `preferredReady`, but polls off the calling
    /// thread and reports back on the main queue. Use this from anywhere that
    /// must not block its thread (e.g. the appex main thread — ViewBridge
    /// hosts treat a stalled main run loop as an unresponsive extension).
    static func preferredReadyAsync(
        timeoutSeconds: TimeInterval,
        log: ((String) -> Void)? = nil,
        completion: @escaping (MTLDevice?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let device = preferredReady(timeoutSeconds: timeoutSeconds, log: log)
            DispatchQueue.main.async { completion(device) }
        }
    }

    /// Prefer discrete GPU; poll/warm until a command queue accepts work or
    /// `timeoutSeconds` elapses (0 = single attempt).
    static func preferredReady(
        timeoutSeconds: TimeInterval,
        log: ((String) -> Void)? = nil
    ) -> MTLDevice? {
        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        var attempt = 0
        var last: MTLDevice?

        repeat {
            attempt += 1
            let devices = MTLCopyAllDevices()
            let discrete = discreteCandidate(from: devices)
            let chosen = discrete ?? MTLCreateSystemDefaultDevice()
            last = chosen

            if let chosen, warmUp(chosen) {
                logDevice(chosen, devices: devices, attempt: attempt, log: log)
                if chosen.isLowPower, discreteCandidate(from: MTLCopyAllDevices()) != nil {
                    // Discrete exists but we still got iGPU — keep trying briefly.
                    log?(
                        "GPU wait attempt \(attempt): still on lowPower '\(chosen.name)', " +
                        "discrete present — retry"
                    )
                } else {
                    return chosen
                }
            } else {
                let name = chosen?.name ?? "nil"
                log?("GPU wait attempt \(attempt): warm-up failed for \(name)")
            }

            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.08)
        } while Date() < deadline

        if let last {
            // Prefer discrete even if the last successful warm-up was iGPU.
            if let discrete = discreteCandidate(from: MTLCopyAllDevices()), warmUp(discrete) {
                logDevice(discrete, devices: MTLCopyAllDevices(), attempt: attempt, log: log)
                return discrete
            }
            logDevice(last, devices: MTLCopyAllDevices(), attempt: attempt, log: log)
        } else {
            log?("MTLDevice=nil after \(attempt) attempt(s)")
        }
        return last
    }

    private static func discreteCandidate(from devices: [MTLDevice]) -> MTLDevice? {
        devices.first { !$0.isLowPower && !$0.isRemovable }
            ?? devices.first { !$0.isLowPower }
    }

    /// Creating a queue + empty commit on the discrete GPU forces it awake
    /// under Automatic graphics switching.
    ///
    /// Uses a bounded wait instead of `waitUntilCompleted()`: under APPEX,
    /// many extension instances can stay alive simultaneously (we never
    /// exit(0) on stop) and all contend for the same discrete GPU. An
    /// unbounded wait lets a congested queue hang this call indefinitely,
    /// leaving that instance's screen permanently frozen/black with no way
    /// to recover. A timed-out attempt is simply treated as "not ready yet"
    /// and retried by the caller instead of blocking forever.
    private static func warmUp(_ device: MTLDevice, timeout: TimeInterval = 0.35) -> Bool {
        guard let queue = device.makeCommandQueue() else { return false }
        guard let buffer = queue.makeCommandBuffer() else { return false }
        let sema = DispatchSemaphore(value: 0)
        buffer.addCompletedHandler { _ in sema.signal() }
        buffer.commit()
        guard sema.wait(timeout: .now() + timeout) == .success else { return false }
        return buffer.status != .error
    }

    private static func logDevice(
        _ chosen: MTLDevice,
        devices: [MTLDevice],
        attempt: Int,
        log: ((String) -> Void)?
    ) {
        let names = devices.map {
            "\($0.name)(lowPower=\($0.isLowPower),removable=\($0.isRemovable))"
        }.joined(separator: ", ")
        log?(
            "MTLDevice=\(chosen.name) lowPower=\(chosen.isLowPower) " +
            "removable=\(chosen.isRemovable) attempt=\(attempt) all=[\(names)]"
        )
    }
}
