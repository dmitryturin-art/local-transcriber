import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct Segment: Codable, Identifiable, Equatable {
    var start: Double
    var end: Double
    var text: String
    var speaker: Int?
    var uncertain: Bool?
    var overlap: Bool?
    var segmentID: String?
    var reviewed: Bool?
    var id: String { segmentID ?? "\(start)-\(end)-\(speaker ?? 0)" }
}

struct Transcript: Codable, Equatable {
    var version: Int
    var source: String
    var model: String
    var duration: Double
    var diarized: Bool
    var speakerCount: Int
    var requestedSpeakers: Int
    var names: [String: String]
    var segments: [Segment]
    var processingSeconds: Double
}

struct TermRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var find: String
    var replacement: String
    var caseSensitive = false
    var wholeWord = true
}

struct ReplacementPreview: Identifiable {
    var index: Int
    var start: Double
    var before: String
    var after: String
    var count: Int
    var id: Int { index }
}

enum TextReplacement {
    static func pattern(find: String, caseSensitive: Bool, wholeWord: Bool) -> NSRegularExpression? {
        guard !find.isEmpty else { return nil }
        var pattern = NSRegularExpression.escapedPattern(for: find)
        if wholeWord { pattern = "(?<![\\p{L}\\p{N}_])" + pattern + "(?![\\p{L}\\p{N}_])" }
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        return try? NSRegularExpression(pattern: pattern, options: options)
    }

    static func apply(_ text: String, find: String, replacement: String,
                      caseSensitive: Bool, wholeWord: Bool) -> (String, Int) {
        guard let regex = pattern(find: find, caseSensitive: caseSensitive, wholeWord: wholeWord) else { return (text, 0) }
        return apply(text, pattern: regex, replacement: replacement)
    }

    static func apply(_ text: String, pattern regex: NSRegularExpression, replacement: String) -> (String, Int) {
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        guard !matches.isEmpty else { return (text, 0) }
        let result = NSMutableString(string: text)
        // Вставляем буквально: $1 и обратные слеши в терминах не являются шаблонами.
        for match in matches.reversed() { result.replaceCharacters(in: match.range, with: replacement) }
        return (result as String, matches.count)
    }
}

struct EditSnapshot {
    var transcript: Transcript
    var names: [String: String]
}

func timecode(_ seconds: Double, subtitle: Bool = false) -> String {
    let ms = max(0, Int((seconds * 1000).rounded()))
    let base = String(format: "%02d:%02d:%02d", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60)
    return subtitle ? base + String(format: ",%03d", ms % 1000) : base
}

final class AppModel: ObservableObject {
    @Published var input: URL?
    @Published var output: URL
    @Published var model = UserDefaults.standard.string(forKey: "asrModel") ?? "gigaam"
    @Published var diarize = UserDefaults.standard.object(forKey: "diarize") as? Bool ?? true
    @Published var speakerCount = UserDefaults.standard.integer(forKey: "speakerCount")
    @Published var running = false
    @Published var cancelling = false
    @Published var progress = 0.0
    @Published var status = "Выберите запись, чтобы начать"
    @Published var eta: Int?
    @Published var fragments = 0
    @Published var latestText = ""
    @Published var transcript: Transcript?
    @Published var names: [String: String] = [:]
    @Published var resultFolder: URL?
    @Published var error: String?
    @Published var playing = false
    @Published var namesSaved = false
    @Published var targeted = false
    @Published var editing = false
    @Published var hasUnsavedChanges = false
    @Published var showReplacement = false
    @Published var showDictionary = false
    @Published var searchText = ""
    @Published var onlyIssues = false
    @Published var findTerm = ""
    @Published var replaceTerm = ""
    @Published var matchCase = false
    @Published var matchWholeWord = true
    @Published var termRules: [TermRule] = []
    @Published var automaticDictionary = UserDefaults.standard.bool(forKey: "automaticDictionary")
    @Published var canUndoEdit = false
    @Published var canRedoEdit = false
    @Published var editMessage = ""
    private var rawDocument: [String: Any] = [:]
    private var originalDocument: Transcript?
    private var undoEdits: [EditSnapshot] = []
    private var redoEdits: [EditSnapshot] = []
    private var lastEditGroup = ""
    private var lastEditTime = Date.distantPast
    private var process: Process?
    private var requestURL: URL?
    private var outputBuffer = Data()
    private var diagnostics = Data()
    private var player: AVPlayer?
    private var playbackObserver: Any?
    private var receivedTerminal = false

    init() {
        let saved = UserDefaults.standard.string(forKey: "outputFolder")
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        output = saved.map { URL(fileURLWithPath: $0) } ?? documents.appendingPathComponent("Транскрипции", isDirectory: true)
        if let data = UserDefaults.standard.data(forKey: "termRules"),
           let rules = try? JSONDecoder().decode([TermRule].self, from: data) { termRules = rules }
    }

    func selectFile() {
        let panel = NSOpenPanel()
        panel.title = "Выберите аудио или видео"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        // Некоторые диктофоны и мессенджеры используют неизвестные macOS
        // расширения. Формат проверяет FFmpeg, а не фильтр системного окна.
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url { setInput(url) }
    }

    func setInput(_ url: URL) {
        guard !running else { return }
        stopPlayback()
        if input == nil, let transcript = transcript, transcript.source == url.lastPathComponent {
            input = url
            return
        }
        guard confirmPendingEdits() else { return }
        input = url
        transcript = nil
        resultFolder = nil
        error = nil
        progress = 0
        status = "Готово к обработке"
        resetEditor()
    }

    func selectOutput() {
        let panel = NSOpenPanel()
        panel.title = "Куда сохранять транскрипции"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            output = url
            UserDefaults.standard.set(url.path, forKey: "outputFolder")
        }
    }

    func start() {
        guard let input = input, !running else { return }
        guard confirmPendingEdits() else { return }
        stopPlayback()
        guard let resources = Bundle.main.resourceURL else { error = "Не найдены ресурсы приложения"; return }
        let engine = resources.appendingPathComponent("engine/local-engine")
        guard FileManager.default.isExecutableFile(atPath: engine.path) else {
            error = "Не найден локальный движок. Используйте полную сборку приложения из DMG."
            return
        }
        do {
            let request: [String: Any] = ["input": input.path, "output": output.path,
                "model": model, "diarize": diarize, "speakers": speakerCount]
            let requestURL = FileManager.default.temporaryDirectory.appendingPathComponent("local-transcriber-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: request).write(to: requestURL, options: .atomic)
            self.requestURL = requestURL
            UserDefaults.standard.set(model, forKey: "asrModel")
            UserDefaults.standard.set(diarize, forKey: "diarize")
            UserDefaults.standard.set(speakerCount, forKey: "speakerCount")
            let task = Process()
            // Запрещаем сеть самому процессу, включая сторонние нативные библиотеки.
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            task.arguments = ["-p", "(version 1)(allow default)(deny network*)", engine.path,
                              "--request", requestURL.path, "--resources", resources.path]
            var environment = ProcessInfo.processInfo.environment
            environment["HF_HUB_OFFLINE"] = "1"
            environment["TRANSFORMERS_OFFLINE"] = "1"
            task.environment = environment
            let stdout = Pipe()
            let stderr = Pipe()
            task.standardOutput = stdout
            task.standardError = stderr
            outputBuffer = Data()
            diagnostics = Data()
            receivedTerminal = false
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                DispatchQueue.main.async { self?.receive(data) }
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                DispatchQueue.main.async {
                    self?.diagnostics.append(data)
                    if let count = self?.diagnostics.count, count > 8000 {
                        self?.diagnostics.removeFirst(count - 8000)
                    }
                }
            }
            task.terminationHandler = { [weak self] ended in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                let tail = stdout.fileHandleForReading.readDataToEndOfFile()
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if !tail.isEmpty { self.receive(tail) }
                    // Последний JSON может прийти до callback завершения процесса.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.finished(ended.terminationStatus) }
                }
            }
            process = task
            transcript = nil
            resetEditor()
            resultFolder = nil
            error = nil
            fragments = 0
            latestText = ""
            eta = nil
            progress = 0
            cancelling = false
            running = true
            status = "Подготовка записи…"
            try task.run()
        } catch {
            self.error = error.localizedDescription
            running = false
            process = nil
            cleanupRequest()
        }
    }

    private func receive(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 10) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            switch type {
            case "progress":
                if let value = event["progress"] as? Double { progress = max(progress, min(100, value)) }
                if !cancelling, let message = event["status"] as? String { status = message }
                eta = event["eta"] as? Int
            case "segment":
                latestText = event["text"] as? String ?? ""
                fragments = event["segments"] as? Int ?? fragments
            case "complete":
                receivedTerminal = true
                progress = 100
                eta = nil
                status = "Транскрипция готова"
                if let path = event["result"] as? String {
                    loadResult(URL(fileURLWithPath: path))
                    if automaticDictionary && !termRules.isEmpty { applyTermDictionary(); saveEdits() }
                }
            case "cancelled":
                receivedTerminal = true
                status = "Обработка отменена"
                eta = nil
            case "error":
                receivedTerminal = true
                error = event["message"] as? String ?? "Не удалось обработать запись"
                status = "Не удалось завершить обработку"
            default: break
            }
        }
    }

    private func finished(_ code: Int32) {
        if !receivedTerminal {
            if cancelling { status = "Обработка отменена" }
            else {
                status = "Не удалось завершить обработку"
                error = "Движок завершился неожиданно (код \(code)). " + (String(data: diagnostics, encoding: .utf8) ?? "")
            }
        }
        running = false
        cancelling = false
        process = nil
        cleanupRequest()
    }

    private func cleanupRequest() {
        if let requestURL = requestURL { try? FileManager.default.removeItem(at: requestURL) }
        requestURL = nil
    }

    func cancel() {
        guard running, !cancelling else { return }
        cancelling = true
        status = "Остановка обработки…"
        process?.terminate()
    }

    func loadResult(_ url: URL) {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let data = try Data(contentsOf: url)
            var result = try decoder.decode(Transcript.self, from: data)
            for index in result.segments.indices {
                if result.segments[index].segmentID == nil { result.segments[index].segmentID = UUID().uuidString }
            }
            rawDocument = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let originalURL = url.deletingLastPathComponent().appendingPathComponent("transcript.original.json")
            originalDocument = (try? Data(contentsOf: originalURL)).flatMap { try? decoder.decode(Transcript.self, from: $0) } ?? result
            transcript = result
            names = result.names
            resultFolder = url.deletingLastPathComponent()
            namesSaved = false
            resetEditor()
            if input?.lastPathComponent != result.source { input = nil }
        } catch { self.error = "Не удалось открыть результат: \(error.localizedDescription)" }
    }

    func openResult() {
        guard !running, confirmPendingEdits() else { return }
        let panel = NSOpenPanel()
        panel.title = "Открыть сохранённую транскрипцию"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            stopPlayback()
            loadResult(url)
        }
    }

    func label(_ speaker: Int?) -> String {
        guard let speaker = speaker else { return "" }
        let name = names[String(speaker)]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Спикер \(speaker)" : name
    }

    func textExports() -> (String, String) {
        guard let transcript = transcript else { return ("", "") }
        var lines = ["Транскрипция: \(transcript.source)", "Модель: \(transcript.model) · Длительность: \(timecode(transcript.duration))",
                     "Автоматическая расшифровка. [?] — голос определён неуверенно; [перекрытие] — одновременная речь.", ""]
        var subtitles: [String] = []
        for (index, row) in transcript.segments.enumerated() {
            let markers = (row.uncertain == true ? " [?]" : "") + (row.overlap == true ? " [перекрытие]" : "")
            let prefix = row.speaker != nil ? "\(label(row.speaker))\(markers): " : ""
            let text = row.text
            lines.append("[\(timecode(row.start))] \(prefix)\(text)")
            lines.append("")
            subtitles.append("\(index + 1)\n\(timecode(row.start, subtitle: true)) --> \(timecode(row.end, subtitle: true))\n\(prefix)\(text)\n")
        }
        return (lines.joined(separator: "\n"), subtitles.joined(separator: "\n"))
    }

    func saveNames() {
        saveEdits()
    }

    func saveEdits() {
        guard var transcript = transcript, let folder = resultFolder else { return }
        do {
            transcript.names = names.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            self.transcript = transcript
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            // Сохраняем исходные файлы один раз, до первого редактирования.
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.original.json").path) {
              for suffix in ["json", "txt", "md", "srt"] {
                let source = folder.appendingPathComponent("transcript.\(suffix)")
                let backup = folder.appendingPathComponent("transcript.original.\(suffix)")
                if FileManager.default.fileExists(atPath: source.path) && !FileManager.default.fileExists(atPath: backup.path) {
                    try FileManager.default.copyItem(at: source, to: backup)
                }
              }
            }
            var document = rawDocument
            let encoded = try JSONSerialization.jsonObject(with: encoder.encode(transcript)) as! [String: Any]
            let originalRows = rawDocument["segments"] as? [[String: Any]] ?? []
            for (key, value) in encoded where key != "segments" { document[key] = value }
            let editedRows = encoded["segments"] as? [[String: Any]] ?? []
            document["segments"] = editedRows.enumerated().map { index, row -> [String: Any] in
                var preserved = index < originalRows.count ? originalRows[index] : [:]
                for key in ["speaker", "uncertain", "overlap", "reviewed", "segment_id"] where row[key] == nil {
                    preserved.removeValue(forKey: key)
                }
                for (key, value) in row { preserved[key] = value }
                return preserved
            }
            let json = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let (text, subtitles) = textExports()
            try text.write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
            try ("# " + text).write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
            try subtitles.write(to: folder.appendingPathComponent("transcript.srt"), atomically: true, encoding: .utf8)
            try json.write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
            rawDocument = document
            namesSaved = true
            hasUnsavedChanges = false
            lastEditGroup = ""
            editMessage = "Правки сохранены во всех форматах"
        } catch { self.error = "Не удалось сохранить правки: \(error.localizedDescription)" }
    }

    func resetEditor() {
        undoEdits = []; redoEdits = []
        canUndoEdit = false; canRedoEdit = false
        hasUnsavedChanges = false; editing = false
        searchText = ""; onlyIssues = false; editMessage = ""; lastEditGroup = ""
    }

    func confirmPendingEdits() -> Bool {
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Сохранить правки транскрипции?"
        alert.informativeText = "Есть изменения текста или спикеров, которые ещё не сохранены."
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Не сохранять")
        alert.addButton(withTitle: "Отмена")
        switch alert.runModal() {
        case .alertFirstButtonReturn: saveEdits(); return !hasUnsavedChanges
        case .alertSecondButtonReturn: hasUnsavedChanges = false; return true
        default: return false
        }
    }

    private func snapshot() -> EditSnapshot? {
        guard let transcript = transcript else { return nil }
        return EditSnapshot(transcript: transcript, names: names)
    }

    private func recordEdit(_ group: String = UUID().uuidString) {
        guard let snapshot = snapshot() else { return }
        if group != lastEditGroup || Date().timeIntervalSince(lastEditTime) > 2 {
            undoEdits.append(snapshot)
            if undoEdits.count > 100 { undoEdits.removeFirst() }
        }
        lastEditGroup = group; lastEditTime = Date()
        redoEdits = []
        canUndoEdit = !undoEdits.isEmpty; canRedoEdit = false
        hasUnsavedChanges = true; namesSaved = false; editMessage = ""
    }

    func undoEdit() {
        guard !running, let previous = undoEdits.popLast(), let current = snapshot() else { return }
        redoEdits.append(current); transcript = previous.transcript; names = previous.names
        hasUnsavedChanges = true; lastEditGroup = ""; namesSaved = false
        canUndoEdit = !undoEdits.isEmpty; canRedoEdit = true
    }

    func redoEdit() {
        guard !running, let next = redoEdits.popLast(), let current = snapshot() else { return }
        undoEdits.append(current); transcript = next.transcript; names = next.names
        hasUnsavedChanges = true; lastEditGroup = ""; namesSaved = false
        canUndoEdit = true; canRedoEdit = !redoEdits.isEmpty
    }

    private var focusedField: NSTextView? {
        guard let view = NSApp?.keyWindow?.firstResponder as? NSTextView, view.isFieldEditor else { return nil }
        return view
    }

    var canUndoCommand: Bool { focusedField.map { $0.undoManager?.canUndo ?? false } ?? canUndoEdit }
    var canRedoCommand: Bool { focusedField.map { $0.undoManager?.canRedo ?? false } ?? canRedoEdit }
    func undoCommand() { if let view = focusedField { view.undoManager?.undo() } else { undoEdit() } }
    func redoCommand() { if let view = focusedField { view.undoManager?.redo() } else { redoEdit() } }

    func segmentText(_ index: Int, id: String) -> String {
        guard let document = transcript, document.segments.indices.contains(index), document.segments[index].id == id else { return "" }
        return document.segments[index].text
    }

    func editText(_ index: Int, _ text: String, id: String? = nil) {
        guard !running, var document = transcript, document.segments.indices.contains(index),
              id == nil || document.segments[index].id == id,
              document.segments[index].text != text else { return }
        recordEdit("text-\(document.segments[index].id)")
        document.segments[index].text = text; transcript = document
    }

    func editSpeaker(_ index: Int, _ speaker: Int, id: String? = nil) {
        guard !running, var document = transcript, document.segments.indices.contains(index),
              id == nil || document.segments[index].id == id,
              speaker >= 0, speaker <= document.speakerCount else { return }
        let value: Int? = speaker == 0 ? nil : speaker
        guard document.segments[index].speaker != value else { return }
        recordEdit()
        document.segments[index].speaker = value
        document.segments[index].uncertain = false
        transcript = document
    }

    func renameSpeaker(_ speaker: Int, _ name: String) {
        guard names[String(speaker)] != name else { return }
        recordEdit("name-\(speaker)"); names[String(speaker)] = name
    }

    func addSpeaker() {
        guard !running, var document = transcript, document.speakerCount < 8 else { return }
        recordEdit(); document.speakerCount += 1; document.diarized = true; transcript = document
    }

    func markReviewed(_ index: Int) {
        guard !running, var document = transcript, document.segments.indices.contains(index) else { return }
        recordEdit()
        document.segments[index].reviewed = !(document.segments[index].reviewed ?? false)
        transcript = document
    }

    func restoreOriginal() {
        guard !running, var original = originalDocument else { return }
        recordEdit()
        for index in original.segments.indices {
            original.segments[index].segmentID = transcript?.segments.indices.contains(index) == true
                ? transcript?.segments[index].segmentID : UUID().uuidString
        }
        transcript = original; names = original.names
        editMessage = "Исходная версия восстановлена. Можно отменить или сохранить."
    }

    var visibleIndices: [Int] {
        guard let document = transcript else { return [] }
        return document.segments.indices.filter { index in
            let row = document.segments[index]
            let issue = (row.uncertain == true || row.overlap == true) && row.reviewed != true
            return (!onlyIssues || issue) && (searchText.isEmpty || row.text.localizedCaseInsensitiveContains(searchText))
        }
    }

    var replacementPreview: [ReplacementPreview] {
        guard let document = transcript,
              let pattern = TextReplacement.pattern(find: findTerm, caseSensitive: matchCase, wholeWord: matchWholeWord) else { return [] }
        return document.segments.enumerated().compactMap { index, row in
            let (text, count) = TextReplacement.apply(row.text, pattern: pattern, replacement: replaceTerm)
            guard count > 0 else { return nil }
            return ReplacementPreview(index: index, start: row.start, before: row.text, after: text, count: count)
        }
    }

    func replaceAll() {
        let preview = replacementPreview
        guard !running, !preview.isEmpty, var document = transcript else { return }
        recordEdit()
        for row in preview { document.segments[row.index].text = row.after }
        transcript = document
        editMessage = "Замен: \(preview.reduce(0) { $0 + $1.count }) · реплик: \(preview.count)"
        showReplacement = false
    }

    func rememberReplacement() {
        guard !findTerm.isEmpty else { return }
        let rule = TermRule(find: findTerm, replacement: replaceTerm,
                            caseSensitive: matchCase, wholeWord: matchWholeWord)
        if !termRules.contains(where: { $0.find == rule.find && $0.replacement == rule.replacement
            && $0.caseSensitive == rule.caseSensitive && $0.wholeWord == rule.wholeWord }) { termRules.append(rule) }
        saveDictionary()
    }

    var currentRuleStored: Bool {
        termRules.contains { $0.find == findTerm && $0.replacement == replaceTerm
            && $0.caseSensitive == matchCase && $0.wholeWord == matchWholeWord }
    }

    func removeRule(_ id: UUID) { termRules.removeAll { $0.id == id }; saveDictionary() }

    func saveDictionary() {
        if let data = try? JSONEncoder().encode(termRules) { UserDefaults.standard.set(data, forKey: "termRules") }
        UserDefaults.standard.set(automaticDictionary, forKey: "automaticDictionary")
    }

    func applyTermDictionary() {
        guard !running || receivedTerminal, var document = transcript, !termRules.isEmpty else { return }
        var replacements = 0
        for rule in termRules {
            guard let pattern = TextReplacement.pattern(find: rule.find, caseSensitive: rule.caseSensitive, wholeWord: rule.wholeWord) else { continue }
            for index in document.segments.indices {
                let (text, count) = TextReplacement.apply(document.segments[index].text, pattern: pattern, replacement: rule.replacement)
                document.segments[index].text = text; replacements += count
            }
        }
        guard replacements > 0 else { editMessage = "Совпадений со словарём нет"; return }
        recordEdit(); transcript = document
        editMessage = "Словарь применён: \(replacements) замен. Можно отменить."
    }

    func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textExports().0, forType: .string)
    }

    func showFolder() {
        if let folder = resultFolder { NSWorkspace.shared.open(folder) }
    }

    func play(at seconds: Double) {
        guard let input = input else { return }
        stopPlayback()
        let audio = AVPlayer(url: input)
        player = audio
        audio.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        audio.play()
        playing = true
        playbackObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: audio.currentItem, queue: .main) { [weak self] _ in self?.stopPlayback() }
    }

    func stopPlayback() {
        player?.pause()
        player = nil
        if let observer = playbackObserver { NotificationCenter.default.removeObserver(observer) }
        playbackObserver = nil
        playing = false
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppModel
    private let accent = Color(red: 0.18, green: 0.39, blue: 0.79)

    var body: some View {
        HStack(spacing: 0) {
            settings.frame(width: 340)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(state.transcript == nil ? "Расшифровка записи" : "Транскрипция готова")
                            .font(.system(size: 24, weight: .semibold))
                        Text(state.transcript.map { "\($0.model) · \(timecode($0.duration)) · \($0.segments.count) реплик" }
                            ?? "Текст, временные метки и голоса в одном месте")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { state.openResult() } label: { Image(systemName: "folder") }
                        .help("Открыть сохранённую транскрипцию").disabled(state.running)
                }.padding(28)
                Divider()
                if let transcript = state.transcript { result(transcript) }
                else if state.running { processing }
                else { empty }
            }.frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 920, minHeight: 700)
        .tint(accent)
        .sheet(isPresented: $state.showReplacement) { ReplacementPanel(state: state) }
        .sheet(isPresented: $state.showDictionary) { DictionaryPanel(state: state) }
        .alert("Не удалось выполнить действие", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
            Button("Понятно", role: .cancel) { state.error = nil }
        } message: { Text(state.error ?? "") }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 38)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Голоса").font(.system(size: 25, weight: .bold))
                    Label("Работает без интернета", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("ЗАПИСЬ")
                Button { state.selectFile() } label: {
                    VStack(spacing: 12) {
                        Image(systemName: state.input == nil ? "arrow.down.doc" : "waveform")
                            .font(.system(size: 28)).foregroundStyle(accent)
                        Text(state.input?.lastPathComponent ?? "Выберите или перетащите запись")
                            .font(.system(size: 13, weight: .medium)).lineLimit(3).multilineTextAlignment(.center)
                        Text("Аудио и видео · включая OGG / OPUS").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(20)
                    .background(state.targeted ? accent.opacity(0.13) : Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(state.targeted ? 0.8 : 0.2), style: StrokeStyle(lineWidth: 1, dash: [5])))
                }.buttonStyle(.plain).disabled(state.running)
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $state.targeted) { providers in
                    guard !state.running, let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url = url { DispatchQueue.main.async { state.setInput(url) } }
                    }
                    return true
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("МОДЕЛЬ РАСПОЗНАВАНИЯ")
                Picker("Модель", selection: $state.model) {
                    Text("GigaAM v3").tag("gigaam")
                    Text("Parakeet v3").tag("parakeet")
                }.pickerStyle(.segmented).labelsHidden().disabled(state.running)
                Text(state.model == "gigaam" ? "Русская речь · с пунктуацией" : "Несколько языков · с пунктуацией")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("СПИКЕРЫ")
                Toggle("Разделять по спикерам", isOn: $state.diarize).toggleStyle(.switch).disabled(state.running)
                if state.diarize {
                    HStack {
                        Text("Число спикеров").font(.subheadline)
                        Spacer()
                        Picker("Число спикеров", selection: $state.speakerCount) {
                            Text("Авто").tag(0)
                            ForEach(1...8, id: \.self) { n in Text("\(n)").tag(n) }
                        }.labelsHidden().frame(width: 100).disabled(state.running)
                    }
                    Text("Если знаете число участников, укажите его. Имена можно задать после обработки.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("СОХРАНЕНИЕ")
                Button { state.selectOutput() } label: {
                    HStack { Image(systemName: "folder"); Text(state.output.lastPathComponent).lineLimit(1); Spacer(); Image(systemName: "chevron.right").font(.caption) }
                }.disabled(state.running)
                Text("TXT · Markdown · SRT\nПлюс JSON для повторного открытия")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            if state.running {
                Button(state.cancelling ? "Остановка…" : "Отменить обработку", role: .destructive) { state.cancel() }
                    .frame(maxWidth: .infinity).disabled(state.cancelling)
            } else {
                Button { state.start() } label: {
                    HStack { Image(systemName: "play.fill"); Text("Расшифровать").fontWeight(.semibold) }.frame(maxWidth: .infinity).padding(.vertical, 7)
                }.buttonStyle(.borderedProminent).disabled(state.input == nil).keyboardShortcut(.return, modifiers: [])
            }
        }.padding(24).background(Color(nsColor: .windowBackgroundColor))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(.secondary)
    }

    private var empty: some View {
        VStack(spacing: 18) {
            Image(systemName: "text.bubble").font(.system(size: 60, weight: .light)).foregroundStyle(accent.opacity(0.65))
            Text("Каждому голосу — своя реплика").font(.title3).fontWeight(.medium)
            Text("Загрузите встречу, интервью или лекцию.\nПриложение обработает её на этом Mac\nи сохранит текст с временными метками.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            HStack(spacing: 16) {
                Label("Длинные записи", systemImage: "clock")
                Label("Локальные модели", systemImage: "internaldrive")
            }.font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var processing: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { ProgressView().controlSize(.small); Text(state.status).font(.headline); Spacer(); Text("\(Int(state.progress))%").monospacedDigit() }
            ProgressView(value: state.progress, total: 100)
            HStack {
                Text("Распознано фрагментов: \(state.fragments)")
                Spacer()
                if let eta = state.eta { Text("Примерно \(max(1, eta / 60)) мин осталось") }
            }.font(.caption).foregroundStyle(.secondary)
            if !state.latestText.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("ПОСЛЕДНИЙ ФРАГМЕНТ")
                    Text(state.latestText).font(.body).lineSpacing(5).textSelection(.enabled)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if state.diarize {
                Text("Спикеры получат общие номера после обработки всей записи.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(28)
    }

    private func result(_ transcript: Transcript) -> some View {
        VStack(spacing: 0) {
            if transcript.diarized && transcript.speakerCount > 0 {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Имена спикеров").font(.headline)
                        Spacer()
                        if state.hasUnsavedChanges { Text("Есть правки").font(.caption).foregroundStyle(.secondary) }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200))], alignment: .leading, spacing: 8) {
                        ForEach(1...transcript.speakerCount, id: \.self) { speaker in
                            HStack {
                                Text("\(speaker)").font(.caption).fontWeight(.bold).foregroundStyle(speakerColor(speaker))
                                    .frame(width: 23, height: 23).background(speakerColor(speaker).opacity(0.1)).clipShape(Circle())
                                TextField("Спикер \(speaker)", text: Binding(get: { state.names[String(speaker)] ?? "" },
                                    set: { state.renameSpeaker(speaker, $0) }))
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    Text("Номера идут по первому появлению голоса. Изменения попадут во все форматы.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 28).padding(.vertical, 18)
                Divider()
            }
            editorToolbar
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 19) {
                    ForEach(state.visibleIndices, id: \.self) { index in
                        SegmentEditorRow(state: state, index: index)
                    }
                    if state.visibleIndices.isEmpty { Text("Подходящих реплик нет").foregroundStyle(.secondary) }
                }.padding(28)
            }
            Divider()
            HStack {
                Text(state.hasUnsavedChanges ? "Есть несохранённые правки" : "TXT · MD · SRT сохранены")
                    .font(.caption).foregroundStyle(state.hasUnsavedChanges ? Color.orange : Color.secondary)
                Spacer()
                if state.input == nil { Button("Указать исходную запись") { state.selectFile() } }
                if state.playing { Button { state.stopPlayback() } label: { Image(systemName: "stop.fill") }.help("Остановить прослушивание") }
                Button("Копировать текст") { state.copyText() }
                Button("Сохранить правки") { state.saveEdits() }.disabled(!state.hasUnsavedChanges)
                Button("Открыть папку") { state.showFolder() }.buttonStyle(.borderedProminent)
            }.padding(18)
        }
    }

    private var editorToolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(state.editing ? "Готово" : "Редактировать") { state.editing.toggle() }
                Button { state.undoEdit() } label: { Image(systemName: "arrow.uturn.backward") }.help("Отменить правку").disabled(!state.canUndoEdit)
                Button { state.redoEdit() } label: { Image(systemName: "arrow.uturn.forward") }.help("Повторить правку").disabled(!state.canRedoEdit)
                Spacer()
                Button("Найти и заменить") { state.showReplacement = true }
                Button("Словарь") { state.showDictionary = true }
            }
            HStack {
                TextField("Поиск по тексту", text: $state.searchText).textFieldStyle(.roundedBorder)
                Toggle("Требуют проверки", isOn: $state.onlyIssues).toggleStyle(.checkbox)
            }
            if state.editing {
                HStack {
                    Text("Правьте текст и спикера. Временные метки сохраняются.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Добавить спикера") { state.addSpeaker() }.font(.caption)
                        .disabled((state.transcript?.speakerCount ?? 0) >= 8)
                }
            }
            if !state.editMessage.isEmpty { Text(state.editMessage).font(.caption).foregroundStyle(.secondary) }
        }.padding(.horizontal, 28).padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func speakerColor(_ speaker: Int) -> Color {
        let colors: [Color] = [accent, .purple, .teal, .orange, .pink, .indigo, .brown, .green]
        return colors[(speaker - 1) % colors.count]
    }
}

struct SegmentEditorRow: View {
    @ObservedObject var state: AppModel
    let index: Int
    var body: some View {
        if let document = state.transcript, document.segments.indices.contains(index) {
            let row = document.segments[index]
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Button { state.play(at: row.start) } label: {
                        Label(timecode(row.start), systemImage: "play.circle")
                            .font(.system(size: 11, design: .monospaced))
                    }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(state.input == nil)
                    if state.editing && document.speakerCount > 0 {
                        Picker("Спикер", selection: Binding(get: { row.speaker ?? 0 }, set: { state.editSpeaker(index, $0, id: row.id) })) {
                            Text("Без спикера").tag(0)
                            ForEach(1...document.speakerCount, id: \.self) { n in Text(state.label(n)).tag(n) }
                        }.labelsHidden().frame(maxWidth: 180)
                    } else if let speaker = row.speaker {
                        Text(state.label(speaker)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.blue)
                    }
                    if row.overlap == true { Text("Одновременная речь").font(.caption2).foregroundStyle(.orange) }
                    else if row.uncertain == true { Text("Голос неуверенно").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Button { state.markReviewed(index) } label: {
                        Image(systemName: row.reviewed == true ? "checkmark.seal.fill" : "checkmark.seal")
                            .foregroundStyle(row.reviewed == true ? Color.green : Color.secondary)
                    }.buttonStyle(.plain).help(row.reviewed == true ? "Снять отметку проверки" : "Отметить проверенной")
                }
                if state.editing {
                    TextEditor(text: Binding(get: { state.segmentText(index, id: row.id) },
                        set: { state.editText(index, $0, id: row.id) }))
                        .font(.system(size: 14)).lineSpacing(4)
                        .frame(height: min(180, max(70, CGFloat(row.text.count / 65 + 2) * 22)))
                        .padding(6).background(Color(nsColor: .textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.gray.opacity(0.2)))
                } else {
                    Text(row.text).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct ReplacementPanel: View {
    @ObservedObject var state: AppModel
    var body: some View {
        let preview = state.replacementPreview
        VStack(alignment: .leading, spacing: 16) {
            Text("Найти и заменить").font(.title2).fontWeight(.semibold)
            TextField("Найти термин или фразу", text: $state.findTerm).textFieldStyle(.roundedBorder)
            TextField("Заменить на", text: $state.replaceTerm).textFieldStyle(.roundedBorder)
            HStack {
                Toggle("Учитывать регистр", isOn: $state.matchCase)
                Toggle("Только целое слово", isOn: $state.matchWholeWord)
            }.toggleStyle(.checkbox)
            Text("Совпадений: \(preview.reduce(0) { $0 + $1.count }) · реплик: \(preview.count)")
                .font(.subheadline).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    ForEach(Array(preview.prefix(8))) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(timecode(row.start)).font(.caption).foregroundStyle(.secondary)
                            Text(row.before).foregroundStyle(.secondary)
                            Text(row.after).foregroundStyle(.primary)
                        }.font(.system(size: 13)).textSelection(.enabled)
                    }
                    if preview.count > 8 { Text("И ещё \(preview.count - 8) реплик").font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 130, maxHeight: 300)
            HStack {
                Button(state.currentRuleStored ? "Добавлено в словарь" : "Добавить в словарь") { state.rememberReplacement() }
                    .disabled(state.findTerm.isEmpty || state.currentRuleStored)
                Spacer()
                Button("Закрыть") { state.showReplacement = false }.keyboardShortcut(.cancelAction)
                Button("Заменить все") { state.replaceAll() }.buttonStyle(.borderedProminent)
                    .disabled(preview.isEmpty).keyboardShortcut(.defaultAction)
            }
            Text("После замены можно отменить правку. В файлы изменения попадут при сохранении.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 620)
    }
}

struct DictionaryPanel: View {
    @ObservedObject var state: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Словарь исправлений").font(.title2).fontWeight(.semibold)
            Text("Добавляйте пары через «Найти и заменить». Словарь хранится только на этом Mac.")
                .font(.subheadline).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(state.termRules) { rule in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(rule.find) → \(rule.replacement)")
                                Text((rule.caseSensitive ? "С учётом регистра" : "Любой регистр") + (rule.wholeWord ? " · целое слово" : " · часть слова"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { state.removeRule(rule.id) } label: { Image(systemName: "trash") }.help("Удалить правило")
                        }
                    }
                    if state.termRules.isEmpty { Text("В словаре пока нет правил").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 120, maxHeight: 320)
            Toggle("Применять автоматически после распознавания", isOn: Binding(get: { state.automaticDictionary },
                set: { state.automaticDictionary = $0; state.saveDictionary() })).toggleStyle(.checkbox)
            Text("Правила применяются по порядку. Исходный результат сохраняется отдельно.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Вернуть исходную версию") { state.restoreOriginal(); state.showDictionary = false }
                    .disabled(state.transcript == nil)
                Spacer()
                Button("Закрыть") { state.showDictionary = false }.keyboardShortcut(.cancelAction)
                Button("Применить к транскрипции") { state.applyTermDictionary(); state.showDictionary = false }
                    .disabled(state.termRules.isEmpty || state.transcript == nil).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 620)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = state else { return .terminateNow }
        if !state.running { return state.confirmPendingEdits() ? .terminateNow : .terminateCancel }
        let alert = NSAlert()
        alert.messageText = "Запись ещё обрабатывается"
        alert.informativeText = "Остановить обработку и закрыть приложение?"
        alert.addButton(withTitle: "Продолжить обработку")
        alert.addButton(withTitle: "Остановить и выйти")
        if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        state.cancel()
        // Дождаться очистки временного аудио в рабочем процессе.
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { timer in
            if !state.running { timer.invalidate(); NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}

@main
struct LocalTranscriberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppModel()
    var body: some Scene {
        WindowGroup("Голоса") {
            ContentView().environmentObject(state).onAppear { delegate.state = state }
        }.defaultSize(width: 1020, height: 780)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Выбрать запись…") { state.selectFile() }.keyboardShortcut("o").disabled(state.running)
                    Button("Открыть транскрипцию…") { state.openResult() }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(state.running)
                }
                CommandGroup(replacing: .undoRedo) {
                    Button("Отменить правку") { state.undoCommand() }.keyboardShortcut("z").disabled(!state.canUndoCommand || state.running)
                    Button("Повторить правку") { state.redoCommand() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!state.canRedoCommand || state.running)
                }
                CommandGroup(replacing: .saveItem) {
                    Button("Сохранить правки") { state.saveEdits() }.keyboardShortcut("s").disabled(!state.hasUnsavedChanges || state.running)
                }
                CommandMenu("Транскрипция") {
                    Button("Найти и заменить…") { state.showReplacement = true }.keyboardShortcut("f").disabled(state.transcript == nil || state.running)
                    Button("Словарь исправлений…") { state.showDictionary = true }.disabled(state.running)
                }
            }
    }
}
