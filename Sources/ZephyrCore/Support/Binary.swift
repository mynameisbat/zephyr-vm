import Foundation

// Small helpers for decoding fixed-layout binary structures (disk headers, boot images).

extension Data {
    @inline(__always)
    private func load<T: FixedWidthInteger>(_ offset: Int, as: T.Type) -> T {
        precondition(offset >= 0 && offset + MemoryLayout<T>.size <= count, "read past end of buffer")
        return withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
    }

    func u8(_ offset: Int) -> UInt8 { self[startIndex + offset] }
    func le16(_ offset: Int) -> UInt16 { UInt16(littleEndian: load(offset, as: UInt16.self)) }
    func le32(_ offset: Int) -> UInt32 { UInt32(littleEndian: load(offset, as: UInt32.self)) }
    func le64(_ offset: Int) -> UInt64 { UInt64(littleEndian: load(offset, as: UInt64.self)) }
    func be32(_ offset: Int) -> UInt32 { UInt32(bigEndian: load(offset, as: UInt32.self)) }
    func be64(_ offset: Int) -> UInt64 { UInt64(bigEndian: load(offset, as: UInt64.self)) }

    /// Returns a zero-based copy of a sub-range (avoids index arithmetic on slices).
    func bytes(_ offset: Int, _ length: Int) -> Data {
        precondition(offset >= 0 && offset + length <= count, "read past end of buffer")
        return Data(self[(startIndex + offset)..<(startIndex + offset + length)])
    }

    /// Decodes a NUL-terminated (or NUL-padded) ASCII/UTF-8 field.
    func cString(_ offset: Int, _ length: Int) -> String {
        let field = bytes(offset, length)
        let end = field.firstIndex(of: 0) ?? field.endIndex
        return String(decoding: field[field.startIndex..<end], as: UTF8.self)
    }

    mutating func appendLE32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

@inline(__always)
func alignUp(_ value: UInt64, _ alignment: UInt64) -> UInt64 {
    (value + alignment - 1) / alignment * alignment
}

@inline(__always)
func alignUp(_ value: Int, _ alignment: Int) -> Int {
    (value + alignment - 1) / alignment * alignment
}
