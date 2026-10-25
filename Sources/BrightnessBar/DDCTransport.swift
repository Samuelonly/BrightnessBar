import AppKit
import Darwin
import IOKit

/// DDC/CI transport for external displays on Apple Silicon, through the private
/// IOAVService IOKit calls (same approach as MonitorControl / AetherSwitch).
///
/// Get reply layout (verified):
/// [0]=0x6E src [1]=0x88 len [2]=0x02 [3]=0 [4]=VCP code [5]=result
/// [6..7]=maximum [8..9]=current [10]=XOR checksum seeded 0x50.
///
/// All I2C traffic is serialized on one queue: DDC does not interleave. Public
/// methods wrap `queue.sync`; the private helpers below must only be called
/// inside those blocks (never re-enter queue.sync).
final class DDCTransport {
    static let shared: DDCTransport? = DDCTransport()

    struct Endpoint {
        let service: CFTypeRef
        let chip: UInt32
        let identity: Identity
    }

    struct Identity: Equatable {
        let vendor: UInt32
        let product: UInt32
        let serial: UInt32
    }

    typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private enum Command: UInt8 {
        case brightness = 0x10
    }

    private let queue = DispatchQueue(label: "brightnessbar.ddc")
    private let create: Create
    private let read: Transfer
    private let write: Transfer
    private var maxCache: [ObjectIdentifier: UInt16] = [:]

    private init?() {
        guard let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let c = dlsym(ioKit, "IOAVServiceCreateWithService"),
              let r = dlsym(ioKit, "IOAVServiceReadI2C"),
              let w = dlsym(ioKit, "IOAVServiceWriteI2C") else { return nil }
        create = unsafeBitCast(c, to: Create.self)
        read = unsafeBitCast(r, to: Transfer.self)
        write = unsafeBitCast(w, to: Transfer.self)
    }

    /// External panels show up as DCPAVServiceProxy services with Location
    /// "External"; each must yield a valid EDID, which becomes its identity.
    func endpoints() -> [Endpoint] {
        return queue.sync {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return [] }
            defer { IOObjectRelease(iterator) }

            var result: [Endpoint] = []
            while case let proxy = IOIteratorNext(iterator), proxy != 0 {
                defer { IOObjectRelease(proxy) }
                guard let location = IORegistryEntryCreateCFProperty(proxy, "Location" as CFString, nil, 0)?.takeRetainedValue() as? String,
                      location == "External",
                      let service = create(nil, proxy)?.takeRetainedValue() else { continue }

                var edid = [UInt8](repeating: 0, count: 128)
                guard edid.withUnsafeMutableBytes({ raw -> Bool in
                    guard let base = raw.baseAddress else { return false }
                    return read(service, 0x50, 0, base, 128) == kIOReturnSuccess
                }), let identity = Self.identity(edid) else { continue }

                var chip: UInt32 = 0x37
                var parent: io_object_t = 0
                if IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) == KERN_SUCCESS {
                    defer { IOObjectRelease(parent) }
                    if let provider = IORegistryEntryCreateCFProperty(parent, "EPICProviderClass" as CFString, nil, 0)?.takeRetainedValue() as? String,
                       provider == "AppleDCPMCDP29XX" {
                        chip = 0xB7
                    }
                }
                result.append(Endpoint(service: service, chip: chip, identity: identity))
            }
            return result
        }
    }

    /// EDID header + wrapping-add checksum, then the identity fields that match
    /// CGDisplayVendorNumber/ModelNumber/SerialNumber.
    static func identity(_ edid: [UInt8]) -> Identity? {
        guard edid.count >= 128, Array(edid.prefix(8)) == [0, 255, 255, 255, 255, 255, 255, 0],
              edid.prefix(128).reduce(UInt8(0), &+) == 0 else { return nil }
        return Identity(vendor: UInt32(edid[8]) << 8 | UInt32(edid[9]),
                        product: UInt32(edid[10]) | UInt32(edid[11]) << 8,
                        serial: UInt32(edid[12]) | UInt32(edid[13]) << 8 | UInt32(edid[14]) << 16 | UInt32(edid[15]) << 24)
    }

    /// Reads brightness as raw VCP (current, max) for an endpoint.
    func readBrightness(_ endpoint: Endpoint) -> (max: UInt16, current: UInt16)? {
        return queue.sync {
            if let (max, current) = readValue(endpoint, attempts: 5) {
                maxCache[ObjectIdentifier(endpoint.service as AnyObject)] = max
                return (max, current)
            }
            return nil
        }
    }

    /// Writes brightness as a percentage (0...1) of the panel's own VCP range.
    func writeBrightness(_ endpoint: Endpoint, percent: Double) -> Bool {
        return queue.sync {
            let maxValue: UInt16
            if let cached = maxCache[ObjectIdentifier(endpoint.service as AnyObject)] {
                maxValue = cached
            } else if let (m, _) = readValue(endpoint, attempts: 2) {
                maxCache[ObjectIdentifier(endpoint.service as AnyObject)] = m
                maxValue = m
            } else {
                return false
            }

            let clamped = min(max(percent, 0), 1) * Double(maxValue)
            let value = UInt16(clamped.rounded())
            var packet = setPacket(.brightness, value)
            for _ in 0..<2 {
                usleep(10_000)
                let sent = packet.withUnsafeMutableBytes { raw -> Bool in
                    guard let base = raw.baseAddress else { return false }
                    return write(endpoint.service, endpoint.chip, 0x51, base, UInt32(raw.count)) == kIOReturnSuccess
                }
                if !sent { return false }
            }
            usleep(50_000)
            return true
        }
    }

    // MARK: - Protocol (queue-internal)

    private func getPacket(_ command: Command) -> [UInt8] {
        let bytes: [UInt8] = [0x82, 0x01, command.rawValue]
        return bytes + [bytes.reduce(UInt8(0x6E), ^)]
    }

    private func setPacket(_ command: Command, _ value: UInt16) -> [UInt8] {
        let bytes: [UInt8] = [0x84, 0x03, command.rawValue, UInt8(value >> 8), UInt8(value & 0xFF)]
        return bytes + [bytes.reduce(UInt8(0x6E ^ 0x51), ^)]
    }

    private func readValue(_ endpoint: Endpoint, attempts: Int) -> (UInt16, UInt16)? {
        var packet = getPacket(.brightness)
        var reply = [UInt8](repeating: 0, count: 11)
        for _ in 0..<attempts {
            var sent = true
            for _ in 0..<2 {
                usleep(10_000)
                let ok = packet.withUnsafeMutableBytes { raw -> Bool in
                    guard let base = raw.baseAddress else { return false }
                    return write(endpoint.service, endpoint.chip, 0x51, base, UInt32(raw.count)) == kIOReturnSuccess
                }
                if !ok { sent = false; break }
            }
            guard sent else { usleep(20_000); continue }
            usleep(endpoint.chip == 0xB7 ? 100_000 : 50_000)
            let received = reply.withUnsafeMutableBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                return read(endpoint.service, endpoint.chip, 0, base, UInt32(raw.count)) == kIOReturnSuccess
            }
            if received, let reading = Self.parse(reply, command: .brightness) {
                return reading
            }
            usleep(20_000)
        }
        return nil
    }

    private static func parse(_ reply: [UInt8], command: Command) -> (max: UInt16, current: UInt16)? {
        guard reply.count >= 11, reply[0] == 0x6E, reply[1] == 0x88, reply[2] == 0x02,
              reply[3] == 0, reply[4] == command.rawValue, reply[5] == 0,
              reply.prefix(11).reduce(UInt8(0x50), ^) == 0 else { return nil }
        let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        guard maximum > 0, current <= maximum else { return nil }
        return (maximum, current)
    }
}
