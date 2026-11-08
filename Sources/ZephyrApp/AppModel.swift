import AppKit
import Foundation
import ZephyrCore

/// App-wide state: imported images, devices and their sessions.
@MainActor
final class AppModel: ObservableObject {
    struct Task: Equatable {
        var title: String
        var fraction: Double
    }

    @Published private(set) var images: [ImageManifest] = []
    @Published private(set) var machines: [MachineBundle] = []
    @Published var task: Task?
    @Published var errorMessage: String?

    let imageStore = ImageStore()
    lazy var machineStore = MachineStore(images: imageStore)
    private var sessions: [UUID: DeviceSession] = [:]
    let gpu = GPUSession()

    /// Releases of the LineageOS-for-QEMU project (GitHub Actions builds, attested).
    static let releasesAPI = URL(string: "https://api.github.com/repos/jqssun/android-lineage-qemu/releases/latest")!

    init() {
        refresh()
    }

    func refresh() {
        images = imageStore.list()
        machines = machineStore.list()
        for machine in machines {
            sessions[machine.id]?.update(bundle: machine)
        }
    }

    func session(for id: UUID) -> DeviceSession? {
        if let existing = sessions[id] { return existing }
        guard let bundle = machines.first(where: { $0.id == id }) else { return nil }
        let session = DeviceSession(bundle: bundle, images: imageStore)
        sessions[id] = session
        return session
    }

    var runningSessions: [DeviceSession] {
        sessions.values.filter { $0.phase.isRunning }
    }

    // MARK: - Devices

    func createMachine(name: String, imageID: String, display: DisplaySpec, cpus: Int, memoryMiB: Int, dataGiB: Int) -> MachineBundle? {
        var spec = MachineSpec(name: name, imageID: imageID, cpuCount: cpus, memoryMiB: memoryMiB, display: display, dataDiskGiB: dataGiB)
        spec.audio = true
        do {
            let bundle = try machineStore.create(spec)
            refresh()
            return bundle
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func delete(_ machine: MachineBundle) {
        if let session = sessions[machine.id], session.phase.isRunning { return }
        do {
            try machineStore.delete(machine)
            sessions[machine.id] = nil
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func factoryReset(_ machine: MachineBundle) {
        if let session = sessions[machine.id], session.phase.isRunning { return }
        do {
            try machineStore.reset(machine)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealInFinder(_ machine: MachineBundle) {
        NSWorkspace.shared.activateFileViewerSelecting([machine.url])
    }

    // MARK: - Images

    func importImage(from url: URL) async {
        task = Task(title: "Đang nhập ảnh…", fraction: 0)
        let store = imageStore
        do {
            _ = try await DeviceSession.background {
                try store.importImage(from: url) { title, fraction in
                    DispatchQueue.main.async { [weak self] in self?.task = Task(title: title, fraction: fraction) }
                }
            }
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
        task = nil
    }

    /// Downloads the latest arm64 LineageOS VM build and imports it.
    func downloadLatestImage() async {
        task = Task(title: "Đang tìm bản mới nhất…", fraction: 0)
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.releasesAPI)
            guard let release = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = release["assets"] as? [[String: Any]],
                  let asset = assets.first(where: { ($0["name"] as? String ?? "").hasPrefix("UTM-VM-") && ($0["name"] as? String ?? "").contains("arm64") }),
                  let name = asset["name"] as? String,
                  let urlString = asset["browser_download_url"] as? String,
                  let url = URL(string: urlString) else {
                throw ZephyrError.notFound("Không tìm thấy bản arm64 trong bản phát hành mới nhất")
            }
            let folder = try ZephyrPaths.ensure(ZephyrPaths.downloads.appendingPathComponent(UUID().uuidString))
            defer { try? FileManager.default.removeItem(at: folder) }
            let destination = folder.appendingPathComponent(name)
            try await Downloader.download(url, to: destination) { [weak self] fraction in
                self?.task = Task(title: "Đang tải \(name)…", fraction: fraction)
            }
            await importImage(from: destination)
        } catch {
            errorMessage = error.localizedDescription
        }
        task = nil
    }
}

/// URLSession download with progress reporting (delegate-based: async helpers skip progress callbacks).
enum Downloader {
    @MainActor
    static func download(_ url: URL, to destination: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = ProgressDelegate(destination: destination, progress: progress, completion: { continuation.resume(with: $0) })
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: url).resume()
            session.finishTasksAndInvalidate()
        }
    }

    final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {
        let destination: URL
        let progress: @MainActor (Double) -> Void
        var completion: ((Result<Void, Error>) -> Void)?

        init(destination: URL, progress: @escaping @MainActor (Double) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
            self.destination = destination
            self.progress = progress
            self.completion = completion
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
            do {
                guard status < 400 else { throw ZephyrError.notFound("Tải thất bại (HTTP \(status))") }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                completion?(.success(()))
            } catch {
                completion?(.failure(error))
            }
            completion = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { completion?(.failure(error)) }
            completion = nil
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            Task { @MainActor in self.progress(fraction) }
        }
    }
}
