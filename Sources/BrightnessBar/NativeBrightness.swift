import AppKit
import Darwin

/// Built-in panel brightness through the private DisplayServices framework.
/// Symbols resolved at runtime; all calls take a CGDirectDisplayID.
enum NativeBrightness {
    private typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>?) -> Int32
    private typealias Set = @convention(c) (UInt32, Float) -> Bool
    private typealias SetSmooth = @convention(c) (UInt32, Float) -> Bool

    private static let symbols: (get: Get, set: Set, smooth: SetSmooth?)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let g = dlsym(handle, "DisplayServicesGetBrightness"),
              let s = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        let smooth = dlsym(handle, "DisplayServicesSetBrightnessSmooth").map { unsafeBitCast($0, to: SetSmooth.self) }
        return (unsafeBitCast(g, to: Get.self), unsafeBitCast(s, to: Set.self), smooth)
    }()

    /// Current level in 0...1, or nil when unavailable.
    static func get(_ displayID: UInt32) -> Double? {
        guard let symbols else { return nil }
        var value: Float = 0
        return symbols.get(displayID, &value) == 0 && value.isFinite && (0...1).contains(value) ? Double(value) : nil
    }

    /// Prefers the smooth (animated) setter, falls back to the absolute one.
    static func set(_ displayID: UInt32, to level: Double, animated: Bool) {
        guard let symbols else { return }
        let target = Float(min(max(level, 0), 1))
        if animated, let smooth = symbols.smooth, let current = get(displayID) {
            if smooth(displayID, target - Float(current)) { return }
        }
        _ = symbols.set(displayID, target)
    }
}

/// Fires when the built-in panel's brightness changes (brightness keys, Control
/// Center, …). Registers through DisplayServices' private notification API and
/// re-posts a local notification; the payload is undocumented, so the current
/// value is always re-read instead of trusted.
final class SystemBrightnessObserver {
    static let didChange = Notification.Name("brightnessBar.systemBrightnessChanged")

    private typealias Callback = @convention(c) (CFNotificationCenter?, UnsafeMutableRawPointer?, CFNotificationName, UnsafeRawPointer?, CFDictionary?) -> Void
    private typealias Register = @convention(c) (UInt32, UInt32, Callback) -> Int32

    private static let register: Register? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let r = dlsym(handle, "DisplayServicesRegisterForBrightnessChangeNotifications") else { return nil }
        return unsafeBitCast(r, to: Register.self)
    }()

    /// Subscribes to changes of one display. Non-capturing callback, safe as a C thunk.
    static func start(_ displayID: UInt32) -> Bool {
        guard let register else { return false }
        return register(displayID, displayID) { _, _, _, _, _ in
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: SystemBrightnessObserver.didChange, object: nil)
            }
        } == 0
    }
}
