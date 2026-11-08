import Foundation
import CoreGraphics
import GRPCCore
import GRPCNIOTransportHTTP2

private typealias Controller = Android_Emulation_Control_EmulatorController

/// One decoded screen frame (RGBA8888, tightly packed, top-left origin).
public struct EmulatorFrame: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let rgba: Data
    public let sequence: UInt32

    /// Alpha is ignored: the emulator may leave it at 0 for opaque RGB content.
    public func makeCGImage() -> CGImage? {
        guard width > 0, height > 0, rgba.count >= width * height * 4,
              let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// gRPC client for the Android Emulator's `EmulatorController` service (`-grpc <port>`).
public final class EmulatorClient: @unchecked Sendable {
    private let client: GRPCClient<HTTP2ClientTransport.Posix>
    private let controller: Controller.Client<HTTP2ClientTransport.Posix>
    private let runTask: Task<Void, Never>

    public init(port: Int = EmulatorProcess.defaultGRPCPort, host: String = "127.0.0.1") throws {
        let transport = try HTTP2ClientTransport.Posix(
            target: .ipv4(address: host, port: port),
            transportSecurity: .plaintext,
            // A native RGBA frame is ~10 MB; the 4 MB default would reject every one.
            serviceConfig: ServiceConfig(methodConfig: [
                MethodConfig(names: [MethodConfig.Name(service: "")],
                             maxRequestMessageBytes: 64 << 20, maxResponseMessageBytes: 64 << 20),
            ]))
        client = GRPCClient(transport: transport)
        controller = Controller.Client(wrapping: client)
        let c = client
        runTask = Task { try? await c.runConnections() }
    }

    public func close() {
        client.beginGracefulShutdown()
    }

    deinit { client.beginGracefulShutdown() }

    // MARK: Video

    /// Streams frames until cancelled. `width`/`height` of 0 means the device's native size; asking for a
    /// smaller size makes the emulator scale on its side and cuts the bytes per frame.
    public func frames(width: Int = 0, height: Int = 0) -> AsyncThrowingStream<EmulatorFrame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var format = Android_Emulation_Control_ImageFormat()
                    format.format = .rgba8888
                    format.width = UInt32(width)
                    format.height = UInt32(height)
                    try await self.controller.streamScreenshot(request: ClientRequest(message: format)) { response in
                        for try await image in response.messages {
                            let w = Int(image.format.width), h = Int(image.format.height)
                            guard w > 0, h > 0, !image.image.isEmpty else { continue }   // display inactive
                            continuation.yield(EmulatorFrame(width: w, height: h, rgba: image.image, sequence: image.seq))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Native display size, taken from the first frame.
    public func displaySize() async throws -> (width: Int, height: Int) {
        for try await frame in frames() { return (frame.width, frame.height) }
        throw ZephyrError.vm("Emulator không gửi khung hình nào.")
    }

    // MARK: Input

    /// `x`/`y` are in device pixels. `pressed == false` lifts the finger.
    public func sendTouch(x: Int, y: Int, pressed: Bool, identifier: Int = 0) async throws {
        var touch = Android_Emulation_Control_Touch()
        touch.x = Int32(x)
        touch.y = Int32(y)
        touch.identifier = Int32(identifier)
        touch.pressure = pressed ? 1024 : 0
        var event = Android_Emulation_Control_TouchEvent()
        event.touches = [touch]
        _ = try await controller.sendTouch(request: ClientRequest(message: event))
    }

    /// Named key using DOM names (`Enter`, `Backspace`, `ArrowLeft`, `Escape`, …).
    public func sendKey(_ key: String) async throws {
        var event = Android_Emulation_Control_KeyboardEvent()
        event.eventType = .keypress
        event.key = key
        _ = try await controller.sendKey(request: ClientRequest(message: event))
    }

    /// Types literal text.
    public func sendText(_ text: String) async throws {
        var event = Android_Emulation_Control_KeyboardEvent()
        event.eventType = .keypress
        event.text = text
        _ = try await controller.sendKey(request: ClientRequest(message: event))
    }
}
