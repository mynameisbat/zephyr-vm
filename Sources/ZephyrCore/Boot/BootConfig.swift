import Foundation

/// Builds the Linux bootconfig blob that Android bootloaders append to the end of the initrd.
///
/// Layout: `[params text][NUL padding][u32 size][u32 checksum]"#BOOTCONFIG\n"`.
/// The kernel finds it by the magic at the very end of the initrd (needs `bootconfig` on the cmdline).
public enum BootConfig {
    static let magic = Data("#BOOTCONFIG\n".utf8)

    public static func encode(_ text: String) -> Data {
        var body = Data(text.utf8)
        if body.last != UInt8(ascii: "\n") { body.append(UInt8(ascii: "\n")) }
        body.append(0)
        while body.count % 4 != 0 { body.append(0) }

        let checksum = body.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        var blob = body
        blob.appendLE32(UInt32(body.count))
        blob.appendLE32(checksum)
        blob.append(magic)
        return blob
    }
}
