import Foundation

/// A partition from a GUID partition table.
public struct GPTPartition: Codable, Hashable {
    /// 1-based partition number (matches Linux `vdaN` naming).
    public let number: Int
    public let name: String
    public let firstLBA: UInt64
    public let lastLBA: UInt64

    public var offset: UInt64 { firstLBA * GPT.sectorSize }
    public var size: UInt64 { (lastLBA - firstLBA + 1) * GPT.sectorSize }
}

public enum GPT {
    public static let sectorSize: UInt64 = 512

    /// Reads the primary GPT of a raw disk image.
    public static func partitions(of file: RandomAccessFile) throws -> [GPTPartition] {
        let header = try file.read(at: sectorSize, count: 92)
        guard header.bytes(0, 8) == Data("EFI PART".utf8) else {
            throw ZephyrError.invalidFormat("\(file.url.lastPathComponent) has no GPT partition table")
        }
        let entriesLBA = header.le64(72)
        let entryCount = Int(header.le32(80))
        let entrySize = Int(header.le32(84))
        guard entrySize >= 128, entryCount <= 1024 else {
            throw ZephyrError.invalidFormat("Unexpected GPT layout in \(file.url.lastPathComponent)")
        }
        let table = try file.read(at: entriesLBA * sectorSize, count: entryCount * entrySize)

        var result: [GPTPartition] = []
        for index in 0..<entryCount {
            let base = index * entrySize
            let typeGUID = table.bytes(base, 16)
            if typeGUID.allSatisfy({ $0 == 0 }) { continue }
            let nameBytes = table.bytes(base + 56, 72)
            var units: [UInt16] = []
            for k in stride(from: 0, to: 72, by: 2) {
                let unit = nameBytes.le16(k)
                if unit == 0 { break }
                units.append(unit)
            }
            result.append(GPTPartition(
                number: index + 1,
                name: String(decoding: units, as: UTF16.self),
                firstLBA: table.le64(base + 32),
                lastLBA: table.le64(base + 40)
            ))
        }
        return result
    }

    public static func partition(named name: String, in file: RandomAccessFile) throws -> GPTPartition {
        guard let part = try partitions(of: file).first(where: { $0.name == name }) else {
            throw ZephyrError.notFound("Partition '\(name)' not found in \(file.url.lastPathComponent)")
        }
        return part
    }
}
