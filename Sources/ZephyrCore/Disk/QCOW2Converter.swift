import Compression
import Foundation

/// Converts a QCOW2 (v2/v3) disk image into a raw, sparse disk image.
///
/// Virtualization.framework only reads raw images, while the LineageOS VM bundles ship as QCOW2.
/// Unallocated and all-zero clusters are left as holes, so on APFS the raw file only occupies
/// as much space as the data actually stored in it.
public enum QCOW2Converter {
    public struct Header {
        public let version: UInt32
        public let clusterBits: UInt32
        public let virtualSize: UInt64
        public let l1Size: UInt32
        public let l1TableOffset: UInt64
        public let compressionType: UInt8

        public var clusterSize: Int { 1 << Int(clusterBits) }
    }

    private static let magic: UInt32 = 0x5146_49FB // "QFI\xfb"
    private static let offsetMask: UInt64 = 0x00FF_FFFF_FFFF_FE00
    private static let compressedFlag: UInt64 = 1 << 62
    private static let zeroFlag: UInt64 = 1

    public static func isQCOW2(_ url: URL) -> Bool {
        guard let file = try? RandomAccessFile(url: url, mode: .read),
              let head = try? file.read(at: 0, count: 4) else { return false }
        return head.be32(0) == magic
    }

    public static func readHeader(_ file: RandomAccessFile) throws -> Header {
        let h = try file.read(at: 0, count: 112)
        guard h.be32(0) == magic else {
            throw ZephyrError.invalidFormat("\(file.url.lastPathComponent) is not a QCOW2 image")
        }
        let version = h.be32(4)
        guard version == 2 || version == 3 else {
            throw ZephyrError.unsupported("QCOW2 version \(version) is not supported")
        }
        guard h.be64(8) == 0 else {
            throw ZephyrError.unsupported("QCOW2 images with a backing file are not supported")
        }
        guard h.be32(32) == 0 else {
            throw ZephyrError.unsupported("Encrypted QCOW2 images are not supported")
        }
        var compressionType: UInt8 = 0
        if version >= 3 {
            let incompatible = h.be64(72)
            // bit 2: external data file, bit 4: extended L2 entries (subclusters)
            if incompatible & (1 << 2) != 0 || incompatible & (1 << 4) != 0 {
                throw ZephyrError.unsupported("QCOW2 feature flags 0x\(String(incompatible, radix: 16)) are not supported")
            }
            let headerLength = h.be32(100)
            if headerLength > 104 {
                compressionType = h.u8(104)
            }
        }
        return Header(
            version: version,
            clusterBits: h.be32(20),
            virtualSize: h.be64(24),
            l1Size: h.be32(36),
            l1TableOffset: h.be64(40),
            compressionType: compressionType
        )
    }

    /// Converts `source` (QCOW2) into a sparse raw image at `destination`.
    /// - Parameter progress: called with a fraction in 0...1 as clusters are processed.
    public static func convert(source: URL, destination: URL, progress: ((Double) -> Void)? = nil) throws {
        let src = try RandomAccessFile(url: source, mode: .read)
        let header = try readHeader(src)
        let clusterSize = header.clusterSize
        let l2Entries = clusterSize / 8
        let srcSize = src.size

        let tmp = destination.appendingPathExtension("partial")
        try FileManager.default.createSparseFile(at: tmp, size: header.virtualSize)
        let dst = try RandomAccessFile(url: tmp, mode: .readWrite)

        let l1 = try src.read(at: header.l1TableOffset, count: Int(header.l1Size) * 8)
        let cluster = UnsafeMutableRawPointer.allocate(byteCount: clusterSize, alignment: 64)
        let zeros = UnsafeMutableRawPointer.allocate(byteCount: clusterSize, alignment: 64)
        let compressed = UnsafeMutableRawPointer.allocate(byteCount: clusterSize * 2 + 512, alignment: 64)
        defer {
            cluster.deallocate()
            zeros.deallocate()
            compressed.deallocate()
        }
        memset(zeros, 0, clusterSize)

        for i in 0..<Int(header.l1Size) {
            let l2Offset = l1.be64(i * 8) & offsetMask
            if l2Offset != 0 {
                let l2 = try src.read(at: l2Offset, count: clusterSize)
                for j in 0..<l2Entries {
                    let guestOffset = (UInt64(i) * UInt64(l2Entries) + UInt64(j)) * UInt64(clusterSize)
                    if guestOffset >= header.virtualSize { break }
                    let length = Int(min(UInt64(clusterSize), header.virtualSize - guestOffset))
                    let entry = l2.be64(j * 8)

                    if entry & compressedFlag != 0 {
                        // Compressed cluster: offset and sector count are packed into the low 62 bits.
                        let x = 62 - (Int(header.clusterBits) - 8)
                        let hostOffset = entry & ((UInt64(1) << UInt64(x)) - 1)
                        let sectors = ((entry >> UInt64(x)) & ((UInt64(1) << UInt64(62 - x)) - 1)) + 1
                        var inLength = Int(sectors * 512 - (hostOffset & 511))
                        inLength = min(inLength, Int(srcSize - hostOffset), clusterSize * 2 + 512)
                        try src.read(into: compressed, at: hostOffset, count: inLength)
                        guard header.compressionType == 0 else {
                            throw ZephyrError.unsupported("zstd-compressed QCOW2 clusters are not supported")
                        }
                        // QCOW2 uses raw DEFLATE, which is what COMPRESSION_ZLIB decodes.
                        let out = compression_decode_buffer(
                            cluster.assumingMemoryBound(to: UInt8.self), clusterSize,
                            compressed.assumingMemoryBound(to: UInt8.self), inLength,
                            nil, COMPRESSION_ZLIB
                        )
                        guard out == clusterSize else {
                            throw ZephyrError.invalidFormat("Corrupt compressed cluster at guest offset \(guestOffset)")
                        }
                    } else {
                        let hostOffset = entry & offsetMask
                        if entry & zeroFlag != 0 || hostOffset == 0 { continue }
                        let got = try src.read(into: cluster, at: hostOffset, count: length)
                        if got < length {
                            memset(cluster + got, 0, length - got)
                        }
                    }

                    if memcmp(cluster, zeros, length) != 0 {
                        try dst.write(cluster, count: length, at: guestOffset)
                    }
                }
            }
            progress?(Double(i + 1) / Double(max(header.l1Size, 1)))
        }

        dst.sync()
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tmp, to: destination)
    }
}
