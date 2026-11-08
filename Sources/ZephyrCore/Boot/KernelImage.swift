import Compression
import Foundation

/// Virtualization.framework's Linux boot loader needs an uncompressed arm64 `Image`.
/// GKI boot images may carry `Image`, `Image.gz` or `Image.lz4`; this normalises them.
public enum KernelImage {
    public enum Format: String {
        case arm64Image = "Image"
        case gzip = "Image.gz"
        case lz4Legacy = "Image.lz4"
        case unknown
    }

    public static func detect(_ data: Data) -> Format {
        if data.count > 0x40, data.le32(0x38) == 0x644D_5241 { return .arm64Image } // "ARM\x64"
        if data.count > 2, data.u8(0) == 0x1F, data.u8(1) == 0x8B { return .gzip }
        if data.count > 4, data.le32(0) == 0x184C_2102 { return .lz4Legacy }
        return .unknown
    }

    public static func uncompressed(_ data: Data) throws -> Data {
        switch detect(data) {
        case .arm64Image:
            return data
        case .gzip:
            return try gunzip(data)
        case .lz4Legacy:
            return try lz4LegacyDecode(data)
        case .unknown:
            throw ZephyrError.unsupported("Unrecognised kernel image format")
        }
    }

    /// Linux "legacy" LZ4 format: magic, then blocks of [u32 compressed size][LZ4 block],
    /// each decoding to at most 8 MiB.
    static func lz4LegacyDecode(_ data: Data) throws -> Data {
        let blockMax = 8 << 20
        var output = Data()
        var offset = 4
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: blockMax)
        defer { out.deallocate() }
        while offset + 4 <= data.count {
            let size = Int(data.le32(offset))
            if size == 0x184C_2102 { offset += 4; continue } // concatenated stream
            offset += 4
            guard size > 0, offset + size <= data.count else { break }
            let produced = data.withUnsafeBytes { raw -> Int in
                let src = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                return compression_decode_buffer(out, blockMax, src, size, nil, COMPRESSION_LZ4_RAW)
            }
            guard produced > 0 else { throw ZephyrError.invalidFormat("Corrupt LZ4 kernel block") }
            output.append(out, count: produced)
            offset += size
        }
        return output
    }

    static func gunzip(_ data: Data) throws -> Data {
        // RFC 1952 header: skip optional fields, then raw DEFLATE until the 8-byte trailer.
        guard data.count > 18 else { throw ZephyrError.invalidFormat("Truncated gzip kernel") }
        let flags = data.u8(3)
        var offset = 10
        if flags & 0x04 != 0 { offset += 2 + Int(data.le16(offset)) }
        if flags & 0x08 != 0 { while data.u8(offset) != 0 { offset += 1 }; offset += 1 }
        if flags & 0x10 != 0 { while data.u8(offset) != 0 { offset += 1 }; offset += 1 }
        if flags & 0x02 != 0 { offset += 2 }
        let expected = Int(data.le32(data.count - 4))
        let capacity = max(expected, data.count * 4)
        var output = Data(count: capacity)
        let produced = output.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity,
                    src.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
                    data.count - offset - 8, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard produced > 0 else { throw ZephyrError.invalidFormat("Corrupt gzip kernel") }
        output.count = produced
        return output
    }
}
