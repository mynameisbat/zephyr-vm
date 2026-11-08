import Foundation

/// Generic `boot.img` (header v3/v4): kernel + generic ramdisk.
/// Layout reference: system/tools/mkbootimg/include/bootimg/bootimg.h
public struct AndroidBootImage {
    public static let pageSize = 4096

    public let headerVersion: UInt32
    public let kernel: Data
    public let ramdisk: Data
    public let cmdline: String

    public init(file: RandomAccessFile, offset: UInt64) throws {
        let h = try file.read(at: offset, count: 4096)
        guard h.bytes(0, 8) == Data("ANDROID!".utf8) else {
            throw ZephyrError.invalidFormat("boot partition does not contain an Android boot image")
        }
        let kernelSize = Int(h.le32(8))
        let ramdiskSize = Int(h.le32(12))
        headerVersion = h.le32(40)
        guard headerVersion == 3 || headerVersion == 4 else {
            throw ZephyrError.unsupported("Boot image header v\(headerVersion) is not supported (need v3 or v4)")
        }
        cmdline = h.cString(44, 1536 + 512).trimmingCharacters(in: .whitespaces)

        let page = Self.pageSize
        let kernelOffset = offset + UInt64(page)
        let ramdiskOffset = kernelOffset + UInt64(alignUp(kernelSize, page))
        kernel = try file.read(at: kernelOffset, count: kernelSize)
        ramdisk = try file.read(at: ramdiskOffset, count: ramdiskSize)
    }
}

/// `vendor_boot.img` (header v3/v4): vendor ramdisk fragments, vendor cmdline, bootconfig.
public struct VendorBootImage {
    public enum RamdiskType: UInt32 {
        case none = 0, platform = 1, recovery = 2, dlkm = 3
    }

    public struct Fragment {
        public let name: String
        public let type: RamdiskType
        public let data: Data
    }

    public let headerVersion: UInt32
    public let cmdline: String
    public let fragments: [Fragment]
    /// Raw bootconfig section (`key=value` lines), without the trailer.
    public let bootconfig: String

    public init(file: RandomAccessFile, offset: UInt64) throws {
        let h = try file.read(at: offset, count: 2128)
        guard h.bytes(0, 8) == Data("VNDRBOOT".utf8) else {
            throw ZephyrError.invalidFormat("vendor_boot partition does not contain a vendor boot image")
        }
        headerVersion = h.le32(8)
        guard headerVersion == 3 || headerVersion == 4 else {
            throw ZephyrError.unsupported("Vendor boot header v\(headerVersion) is not supported")
        }
        let pageSize = Int(h.le32(12))
        let vendorRamdiskSize = Int(h.le32(24))
        cmdline = h.cString(28, 2048).trimmingCharacters(in: .whitespaces)
        let headerSize = Int(h.le32(2096))
        let dtbSize = Int(h.le32(2100))

        let ramdiskSectionOffset = offset + UInt64(alignUp(headerSize, pageSize))
        let ramdiskSection = try file.read(at: ramdiskSectionOffset, count: vendorRamdiskSize)

        guard headerVersion == 4 else {
            fragments = [Fragment(name: "", type: .platform, data: ramdiskSection)]
            bootconfig = ""
            return
        }

        let tableSize = Int(h.le32(2112))
        let entryCount = Int(h.le32(2116))
        let entrySize = Int(h.le32(2120))
        let bootconfigSize = Int(h.le32(2124))

        let tableOffset = ramdiskSectionOffset
            + UInt64(alignUp(vendorRamdiskSize, pageSize))
            + UInt64(alignUp(dtbSize, pageSize))
        let table = try file.read(at: tableOffset, count: tableSize)

        var parsed: [Fragment] = []
        for i in 0..<entryCount {
            let base = i * entrySize
            let size = Int(table.le32(base))
            let start = Int(table.le32(base + 4))
            let type = RamdiskType(rawValue: table.le32(base + 8)) ?? .none
            let name = table.cString(base + 12, 32)
            guard start + size <= ramdiskSection.count else {
                throw ZephyrError.invalidFormat("vendor ramdisk fragment '\(name)' is out of bounds")
            }
            parsed.append(Fragment(name: name, type: type, data: ramdiskSection.bytes(start, size)))
        }
        fragments = parsed

        let bootconfigOffset = tableOffset + UInt64(alignUp(tableSize, pageSize))
        let raw = bootconfigSize > 0 ? try file.read(at: bootconfigOffset, count: bootconfigSize) : Data()
        bootconfig = String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}
