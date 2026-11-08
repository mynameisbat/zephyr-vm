import Foundation

/// Errors raised by the Zephyr core. Messages are meant to be shown to the user as-is.
public enum ZephyrError: LocalizedError {
    case posix(String, Int32)
    case invalidFormat(String)
    case unsupported(String)
    case notFound(String)
    case vm(String)
    case adb(String)

    public var errorDescription: String? {
        switch self {
        case let .posix(what, code):
            return "\(what): \(String(cString: strerror(code)))"
        case let .invalidFormat(message),
             let .unsupported(message),
             let .notFound(message),
             let .vm(message),
             let .adb(message):
            return message
        }
    }

    static func lastPOSIX(_ what: String) -> ZephyrError {
        .posix(what, errno)
    }
}
