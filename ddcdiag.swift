import CoreGraphics
import Darwin
import Foundation
import IOKit

// Standalone DDC/CI diagnostic. Prints every stage so failures localize.

typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

guard let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
      let c = dlsym(ioKit, "IOAVServiceCreateWithService"),
      let r = dlsym(ioKit, "IOAVServiceReadI2C"),
      let w = dlsym(ioKit, "IOAVServiceWriteI2C") else {
    print("FATAL: IOKit dlopen/dlsym failed"); exit(1)
}
let create = unsafeBitCast(c, to: Create.self)
let read = unsafeBitCast(r, to: Transfer.self)
let write = unsafeBitCast(w, to: Transfer.self)

// DisplayServices
var dsGet: (@convention(c) (UInt32, UnsafeMutablePointer<Float>?) -> Int32)?
var dsSet: (@convention(c) (UInt32, Float) -> Bool)?
if let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
   let g = dlsym(h, "DisplayServicesGetBrightness"), let s = dlsym(h, "DisplayServicesSetBrightness") {
    dsGet = unsafeBitCast(g, to: (@convention(c) (UInt32, UnsafeMutablePointer<Float>?) -> Int32).self)
    dsSet = unsafeBitCast(s, to: (@convention(c) (UInt32, Float) -> Bool).self)
}

print("== CG displays ==")
var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var count: UInt32 = 0
if CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) != .success { print("CGGetOnlineDisplayList failed") }
for i in 0..<Int(count) {
    let id = ids[i]
    var v: Float = 0
    let rc = dsGet?(id, &v) ?? -999
    print("display \(id): builtin=\(CGDisplayIsBuiltin(id) != 0) main=\(CGMainDisplayID() == id) dsGet rc=\(rc) value=\(v)")
}

print("\n== DCPAVServiceProxy enumeration ==")
var iterator: io_iterator_t = 0
guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
    print("IOServiceGetMatchingServices FAILED"); exit(1)
}
defer { IOObjectRelease(iterator) }

var n = 0
while case let proxy = IOIteratorNext(iterator), proxy != 0 {
    defer { IOObjectRelease(proxy) }
    n += 1
    let location = IORegistryEntryCreateCFProperty(proxy, "Location" as CFString, nil, 0)?.takeRetainedValue() as? String ?? "<nil>"
    var parent: io_object_t = 0
    var provider = "<nil>"
    if IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) == KERN_SUCCESS {
        provider = IORegistryEntryCreateCFProperty(parent, "EPICProviderClass" as CFString, nil, 0)?.takeRetainedValue() as? String ?? "<nil>"
        IOObjectRelease(parent)
    }
    print("proxy #\(n): location=\(location) provider=\(provider)")

    guard let service = create(nil, proxy)?.takeRetainedValue() else { print("  IOAVServiceCreateWithService FAILED"); continue }

    // EDID sanity: 128 bytes at chip 0x50
    var edid = [UInt8](repeating: 0, count: 128)
    let edidRC = edid.withUnsafeMutableBytes { raw in read(service, 0x50, 0, raw.baseAddress!, 128) }
    let edidHead = edid.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
    print("  EDID rc=\(edidRC) head=\(edidHead)")

    // VCP get brightness: [0x82, 0x01, 0x10] + XOR seed 0x6E
    var packet: [UInt8] = [0x82, 0x01, 0x10]
    packet.append(packet.reduce(UInt8(0x6E), ^))

    // Chip: DCP29XX panels use 0xB7 (matches AppleDCPMCDP29XX provider above)
    let chip: UInt32 = provider == "AppleDCPMCDP29XX" ? 0xB7 : 0x37
    print("  using chip=0x\(String(chip, radix: 16))")

    var reply = [UInt8](repeating: 0, count: 11)
    for attempt in 1...5 {
        var ok = true
        for _ in 0..<2 {
            usleep(10_000)
            let wRC = packet.withUnsafeMutableBytes { raw in write(service, chip, 0x51, raw.baseAddress!, UInt32(raw.count)) }
            if wRC != 0 { ok = false }
        }
        usleep(chip == 0xB7 ? 100_000 : 50_000)
        let rRC = reply.withUnsafeMutableBytes { raw in read(service, chip, 0, raw.baseAddress!, UInt32(raw.count)) }
        let hex = reply.map { String(format: "%02x", $0) }.joined(separator: " ")
        let checksumOK = reply.prefix(11).reduce(UInt8(0x50), ^) == 0
        // Correct layout: [0]=6E [1]=88 [2]=02 [3]=0 [4]=cmd [5]=result [6..7]=max [8..9]=cur [10]=cksum
        let parsed: String
        if reply[0] == 0x6E, reply[1] == 0x88, reply[2] == 0x02, reply[3] == 0, reply[4] == 0x10, reply[5] == 0, checksumOK {
            let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
            let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
            parsed = "PARSED max=\(maximum) current=\(current)"
        } else { parsed = "rejected" }
        print("  attempt \(attempt): writeOK=\(ok) read=\(rRC) reply=[\(hex)] checksum=\(checksumOK) → \(parsed)")
        if parsed.hasPrefix("PARSED") { break }
        usleep(20_000)
    }
}
if n == 0 { print("NO DCPAVServiceProxy services found") }

print("\nDone.")
