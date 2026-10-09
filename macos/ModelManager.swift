import Foundation
import Combine
import CryptoKit
import AppKit

struct ModelAsset: Codable {
    var path: String
    var group: String
    var url: String
    var size: Int64
    var sha256: String
    var acceptedHashes: [String]
    var acceptedSizes: [Int64]
    var archiveMember: String?
    var archiveSHA256: String?
}

struct AssetReceipt: Codable {
    var hash: String
    var size: Int64
    var modified: Double
}

final class ModelManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var busy = false
    @Published var progress = 0.0
    @Published var message = "Модели хранятся на этом Mac"
    @Published var failure: String?
    @Published var revision = 0
    let directory: URL
    let assets: [ModelAsset]
    private let resources: URL?
    private var receipts: [String: AssetReceipt] = [:]
    private var queue: [ModelAsset] = []
    private var active: ModelAsset?
    private var task: URLSessionDownloadTask?
    private var stopped = false
    private var total = 1
    private var done = 0
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    init(directory: URL? = nil, resources: URL? = Bundle.main.resourceURL) {
        self.resources = resources
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.directory = directory ?? support.appendingPathComponent("Голоса/Models", isDirectory: true)
        if let path = resources?.appendingPathComponent("model-catalog.json"), let data = try? Data(contentsOf: path) {
            assets = (try? JSONDecoder().decode([ModelAsset].self, from: data)) ?? []
        } else { assets = [] }
        super.init()
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: receiptURL) { receipts = (try? JSONDecoder().decode([String: AssetReceipt].self, from: data)) ?? [:] }
        installSmallFiles()
    }

    private var receiptURL: URL { directory.appendingPathComponent("verified.json") }
    private func resumeURL(_ asset: ModelAsset) -> URL { directory.appendingPathComponent(".resume-" + asset.path.replacingOccurrences(of: "/", with: "-") + ".data") }

    private func installSmallFiles() {
        guard let source = resources?.appendingPathComponent("model-support/gigaam-e2e") else { return }
        let target = directory.appendingPathComponent("gigaam-e2e", isDirectory: true)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for name in ["features.json", "tokenizer.model"] {
            let destination = target.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: destination.path) { try? FileManager.default.copyItem(at: source.appendingPathComponent(name), to: destination) }
        }
    }

    func available(_ group: String) -> Bool {
        let selected = assets.filter { $0.group == group || $0.group == "shared" }
        guard !selected.isEmpty else { return false }
        return selected.allSatisfy { asset in
            guard let receipt = receipts[asset.path],
                  let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(asset.path).path),
                  let size = attributes[.size] as? NSNumber,
                  let date = attributes[.modificationDate] as? Date else { return false }
            return size.int64Value == receipt.size && abs(date.timeIntervalSince1970 - receipt.modified) < 0.01
                && ([asset.sha256] + asset.acceptedHashes).contains(receipt.hash)
        }
    }

    func sizeLabel(_ group: String) -> String {
        let bytes = assets.filter { $0.group == group }.reduce(Int64(0)) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func download(_ group: String) {
        guard !busy else { return }
        stopped = false; failure = nil; done = 0; progress = 0
        queue = assets.filter { $0.group == group || $0.group == "shared" }.filter { !verified($0) }
        total = max(1, queue.count); busy = !queue.isEmpty
        if queue.isEmpty { message = "Модель уже готова"; return }
        startNext()
    }

    private func verified(_ asset: ModelAsset) -> Bool {
        guard let receipt = receipts[asset.path], let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(asset.path).path),
              let size = attributes[.size] as? NSNumber, let date = attributes[.modificationDate] as? Date else { return false }
        return size.int64Value == receipt.size && abs(date.timeIntervalSince1970 - receipt.modified) < 0.01
            && ([asset.sha256] + asset.acceptedHashes).contains(receipt.hash)
    }

    private func startNext() {
        guard !stopped else { busy = false; message = "Загрузка приостановлена — можно продолжить"; return }
        guard !queue.isEmpty else { busy = false; progress = 1; message = "Модель готова. Дальше можно работать без интернета."; revision += 1; return }
        let asset = queue.removeFirst(); active = asset
        if let data = try? Data(contentsOf: resumeURL(asset)) { task = session.downloadTask(withResumeData: data) }
        else { task = session.downloadTask(with: URL(string: asset.url)!) }
        message = "Загрузка: \(asset.path.components(separatedBy: "/").last!)"
        task?.resume()
    }

    func pause() {
        guard busy else { return }
        stopped = true
        if let task = task, let asset = active {
            task.cancel { [weak self] data in
                if let data = data, let self = self { try? data.write(to: self.resumeURL(asset), options: .atomic) }
            }
        } else { message = "Завершаем проверку текущего файла…" }
    }

    static func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func checkAndInstall(_ source: URL, asset: ModelAsset, importing: Bool) throws -> AssetReceipt {
        var content = source
        let scratch = directory.appendingPathComponent(".extract-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        if !importing, let member = asset.archiveMember {
            guard try Self.hash(source) == asset.archiveSHA256 else { throw NSError(domain: "Голоса", code: 1, userInfo: [NSLocalizedDescriptionKey: "Контрольная сумма архива не совпала"]) }
            FileManager.default.createFile(atPath: scratch.path, contents: nil)
            let file = try FileHandle(forWritingTo: scratch)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xOf", source.path, member]; process.standardOutput = file; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); try file.close()
            guard process.terminationStatus == 0 else { throw NSError(domain: "Голоса", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не удалось прочитать компонент диаризации из архива"]) }
            content = scratch
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: content.path)
        let size = (attributes[.size] as! NSNumber).int64Value
        let allowedSizes = importing ? [asset.size]+asset.acceptedSizes : [asset.size]
        guard allowedSizes.contains(size) else { throw NSError(domain: "Голоса", code: 3, userInfo: [NSLocalizedDescriptionKey: "Неверный размер файла модели: \(asset.path)"]) }
        let hash = try Self.hash(content)
        let allowedHashes = importing ? [asset.sha256]+asset.acceptedHashes : [asset.sha256]
        guard allowedHashes.contains(hash) else { throw NSError(domain: "Голоса", code: 4, userInfo: [NSLocalizedDescriptionKey: "Модель не прошла проверку целостности: \(asset.path)"]) }
        let destination = directory.appendingPathComponent(asset.path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.appendingPathExtension("new")
        try? FileManager.default.removeItem(at: temporary)
        try FileManager.default.copyItem(at: content, to: temporary)
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: destination) }
        let date = (try FileManager.default.attributesOfItem(atPath: destination.path)[.modificationDate]) as! Date
        return AssetReceipt(hash: hash, size: size, modified: date.timeIntervalSince1970)
    }

    private func saveReceipts() {
        if let data = try? JSONEncoder().encode(receipts) { try? data.write(to: receiptURL, options: .atomic) }
        revision += 1
    }

    func importFolder(_ source: URL) {
        guard !busy else { return }
        busy = true; stopped = false; failure = nil; message = "Проверка уже скачанных моделей…"
        DispatchQueue.global(qos: .utility).async {
            var imported: [String: AssetReceipt] = [:]
            var firstError: String?
            for asset in self.assets {
                let path = source.appendingPathComponent(asset.path)
                if FileManager.default.fileExists(atPath: path.path) {
                    do { imported[asset.path] = try self.checkAndInstall(path, asset: asset, importing: true) }
                    catch { firstError = error.localizedDescription }
                }
            }
            DispatchQueue.main.async {
                for (key, receipt) in imported { self.receipts[key] = receipt }
                self.saveReceipts(); self.installSmallFiles(); self.busy = false
                self.message = imported.isEmpty ? "В папке не найдено совместимых моделей" : "Импортировано файлов: \(imported.count)"
                self.failure = firstError
            }
        }
    }

    func chooseImportFolder() {
        let panel = NSOpenPanel(); panel.title = "Папка с уже скачанными моделями Голоса"
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        if panel.runModal() == .OK, let path = panel.url { importFolder(path) }
    }

    func remove(_ group: String) {
        guard !busy, group == "gigaam" || group == "parakeet" else { return }
        do {
            let folder = directory.appendingPathComponent(group == "gigaam" ? "gigaam-e2e" : "parakeet")
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
            for asset in assets where asset.group == group { receipts.removeValue(forKey: asset.path) }
            saveReceipts(); installSmallFiles(); message = "Модель убрана в Корзину. Можно загрузить снова."
        } catch { failure = error.localizedDescription }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard downloadTask.taskIdentifier == task?.taskIdentifier else { return }
        let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten)/Double(totalBytesExpectedToWrite) : 0
        progress = (Double(done)+min(1,fraction))/Double(total)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let asset = active, downloadTask.taskIdentifier == task?.taskIdentifier else { return }
        let staging = directory.appendingPathComponent(".download-\(UUID().uuidString)")
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw NSError(domain: "Голоса", code: 5, userInfo: [NSLocalizedDescriptionKey: "Сервер модели вернул ошибку"]) }
            try FileManager.default.moveItem(at: location, to: staging)
        } catch { failure = error.localizedDescription; busy = false; task = nil; return }
        task = nil; message = "Проверка целостности модели…"
        DispatchQueue.global(qos: .utility).async {
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                let receipt = try self.checkAndInstall(staging, asset: asset, importing: false)
                DispatchQueue.main.async {
                    self.receipts[asset.path] = receipt; self.saveReceipts(); try? FileManager.default.removeItem(at: self.resumeURL(asset))
                    self.done += 1; self.startNext()
                }
            } catch { DispatchQueue.main.async { self.failure = error.localizedDescription; self.busy = false } }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as NSError?, task.taskIdentifier == self.task?.taskIdentifier else { return }
        if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, let asset = active { try? data.write(to: resumeURL(asset), options: .atomic) }
        self.task = nil; busy = false
        if stopped { message = "Загрузка приостановлена — можно продолжить" }
        else { failure = error.localizedDescription; message = "Загрузка не завершена. Можно повторить." }
    }
}
