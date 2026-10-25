import AppKit
import CoreGraphics
import Darwin

/// Orchestrates brightness across every controllable display. Each online
/// display is probed natively first (built-in panels, Studio Display…); the
/// rest are matched to a DDC endpoint by EDID identity — one identical match,
/// never enumeration order. One percentage applies to all panels, each mapped
/// to its own VCP range.
final class BrightnessController: NSObject {
    struct UIState {
        var interactive: Bool
        var percent: Int
        var status: String
    }

    var onUpdate: ((UIState) -> Void)?

    private let workQueue = DispatchQueue(label: "brightnessbar.work")
    private var nativeIDs: [UInt32] = []
    private var ddcEndpoints: [DDCTransport.Endpoint] = []
    private var currentPercent = 50
    private var nativeObserverStarted = false

    // Slider writes are coalesced: the newest percentage always wins, and a
    // new cycle starts as soon as the previous one finishes.
    private var pendingPercent: Int?
    private var pendingIncludeNative = false
    private var writeInFlight = false

    // Our own native writes also trigger the system brightness notification;
    // ignore those echoes so following the brightness keys never loops.
    private var lastNativeWriteAt: Date?
    private var syncDebounce: DispatchWorkItem?

    private override init() {}

    static func make() -> BrightnessController? {
        guard DDCTransport.shared != nil || NativeBrightness.get(CGMainDisplayID()) != nil else { return nil }
        return BrightnessController()
    }

    func start() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(systemBrightnessChanged),
            name: SystemBrightnessObserver.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        refresh()
    }

    // MARK: - Reading

    /// Re-enumerates displays and reads every panel's current level.
    func refresh() {
        let transport = DDCTransport.shared
        setStatus("读取中…", interactive: false)

        workQueue.async { [weak self] in
            let ids = Self.onlineDisplayIDs()
            let endpoints = transport?.endpoints() ?? []

            var native: [UInt32] = []
            var ddc: [DDCTransport.Endpoint] = []
            var percents: [Double] = []
            var unavailable = 0
            for id in ids {
                if let value = NativeBrightness.get(id) {
                    native.append(id)
                    percents.append(value * 100)
                    continue
                }
                let key = Self.displayIdentity(id)
                let matching = endpoints.filter { $0.identity == key }
                guard matching.count == 1,
                      let reading = transport?.readBrightness(matching[0]), reading.max > 0 else {
                    unavailable += 1
                    continue
                }
                ddc.append(matching[0])
                percents.append(Double(reading.current) / Double(reading.max) * 100)
            }

            DispatchQueue.main.async {
                self?.applyRead(native: native, ddc: ddc, percents: percents, unavailable: unavailable, total: ids.count)
            }
        }
    }

    private func applyRead(native: [UInt32], ddc: [DDCTransport.Endpoint], percents: [Double], unavailable: Int, total: Int) {
        nativeIDs = native
        ddcEndpoints = ddc

        if !nativeObserverStarted, let id = native.first {
            nativeObserverStarted = SystemBrightnessObserver.start(id)
        }

        guard !percents.isEmpty else {
            currentPercent = 0
            setStatus(total == 0 ? "未找到显示器" : "屏幕不可控，请开启显示器 DDC/CI", interactive: false)
            return
        }

        let average = Int((percents.reduce(0, +) / Double(percents.count)).rounded())
        currentPercent = average
        var status = "同步控制 \(percents.count) 块屏幕"
        if unavailable > 0 { status += "，\(unavailable) 块不可控" }
        setStatus(status, interactive: true, percent: average)
    }

    // MARK: - Writing

    /// Slider drag: coalesce and push the newest percentage to every panel.
    func requestSet(_ percent: Int) {
        enqueueSet(percent, includeNative: true)
    }

    private func enqueueSet(_ percent: Int, includeNative: Bool) {
        currentPercent = min(max(percent, 0), 100)
        pendingPercent = currentPercent
        pendingIncludeNative = pendingIncludeNative || includeNative
        drain()
    }

    private func drain() {
        guard !writeInFlight, let percent = pendingPercent else { return }
        let includeNative = pendingIncludeNative
        pendingPercent = nil
        pendingIncludeNative = false
        writeInFlight = true

        if includeNative, !nativeIDs.isEmpty { lastNativeWriteAt = Date() }
        let nativeIDs = self.nativeIDs
        let ddcEndpoints = self.ddcEndpoints
        let transport = DDCTransport.shared

        workQueue.async { [weak self] in
            if includeNative {
                for id in nativeIDs { NativeBrightness.set(id, to: Double(percent) / 100, animated: true) }
            }
            for endpoint in ddcEndpoints {
                _ = transport?.writeBrightness(endpoint, percent: Double(percent) / 100)
            }
            DispatchQueue.main.async {
                self?.writeInFlight = false
                self?.drain()
            }
        }
    }

    // MARK: - System brightness keys

    @objc private func systemBrightnessChanged() {
        if let last = lastNativeWriteAt, Date().timeIntervalSince(last) < 0.8 { return }
        syncDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.followNativeBrightness() }
        syncDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// The user pressed the Mac brightness keys: push the native panel's new
    /// level to every external display.
    private func followNativeBrightness() {
        guard let id = nativeIDs.first, let value = NativeBrightness.get(id) else { return }
        enqueueSet(Int((value * 100).rounded()), includeNative: false)
    }

    @objc private func screensChanged() {
        refresh()
    }

    // MARK: - Helpers

    private func setStatus(_ text: String, interactive: Bool, percent: Int? = nil) {
        onUpdate?(UIState(interactive: interactive, percent: percent ?? currentPercent, status: text))
    }

    private static func onlineDisplayIDs() -> [UInt32] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return (0..<Int(count)).map { ids[$0] }
    }

    private static func displayIdentity(_ id: UInt32) -> DDCTransport.Identity {
        DDCTransport.Identity(vendor: CGDisplayVendorNumber(id),
                              product: CGDisplayModelNumber(id),
                              serial: CGDisplaySerialNumber(id))
    }
}
