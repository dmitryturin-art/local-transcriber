import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct Segment: Codable, Identifiable {
    var start: Double
    var end: Double
    var text: String
    var speaker: Int?
    var uncertain: Bool?
    var overlap: Bool?
    var id: String { "\(start)-\(end)-\(speaker ?? 0)" }
}

struct Transcript: Codable {
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
        input = url
        transcript = nil
        resultFolder = nil
        error = nil
        progress = 0
        status = "Готово к обработке"
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
                if let path = event["result"] as? String { loadResult(URL(fileURLWithPath: path)) }
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
            let result = try decoder.decode(Transcript.self, from: Data(contentsOf: url))
            transcript = result
            names = result.names
            resultFolder = url.deletingLastPathComponent()
            namesSaved = false
            if input?.lastPathComponent != result.source { input = nil }
        } catch { self.error = "Не удалось открыть результат: \(error.localizedDescription)" }
    }

    func openResult() {
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
            let text = row.text.prefix(1).uppercased() + row.text.dropFirst()
            lines.append("[\(timecode(row.start))] \(prefix)\(text)")
            lines.append("")
            subtitles.append("\(index + 1)\n\(timecode(row.start, subtitle: true)) --> \(timecode(row.end, subtitle: true))\n\(prefix)\(text)\n")
        }
        return (lines.joined(separator: "\n"), subtitles.joined(separator: "\n"))
    }

    func saveNames() {
        guard var transcript = transcript, let folder = resultFolder else { return }
        do {
            transcript.names = names.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            self.transcript = transcript
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let (text, subtitles) = textExports()
            try text.write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
            try ("# " + text).write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
            try subtitles.write(to: folder.appendingPathComponent("transcript.srt"), atomically: true, encoding: .utf8)
            try encoder.encode(transcript).write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
            namesSaved = true
        } catch { self.error = "Не удалось сохранить имена: \(error.localizedDescription)" }
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
                        Button(state.namesSaved ? "Имена сохранены" : "Сохранить имена") { state.saveNames() }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200))], alignment: .leading, spacing: 8) {
                        ForEach(1...transcript.speakerCount, id: \.self) { speaker in
                            HStack {
                                Text("\(speaker)").font(.caption).fontWeight(.bold).foregroundStyle(speakerColor(speaker))
                                    .frame(width: 23, height: 23).background(speakerColor(speaker).opacity(0.1)).clipShape(Circle())
                                TextField("Спикер \(speaker)", text: Binding(get: { state.names[String(speaker)] ?? "" },
                                    set: { state.names[String(speaker)] = $0; state.namesSaved = false }))
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    Text("Номера идут по первому появлению голоса. Изменения попадут во все форматы.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 28).padding(.vertical, 18)
                Divider()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 19) {
                    ForEach(transcript.segments) { row in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 9) {
                                Button { state.play(at: row.start) } label: {
                                    Label(timecode(row.start), systemImage: "play.circle")
                                        .font(.system(size: 11, design: .monospaced))
                                }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(state.input == nil)
                                if let speaker = row.speaker { Text(state.label(speaker)).font(.system(size: 12, weight: .semibold)).foregroundStyle(speakerColor(speaker)) }
                                if row.overlap == true { Text("Одновременная речь").font(.caption2).foregroundStyle(.orange) }
                                else if row.uncertain == true { Text("Голос неуверенно").font(.caption2).foregroundStyle(.secondary) }
                            }
                            Text(row.text.prefix(1).uppercased() + row.text.dropFirst()).font(.system(size: 14))
                                .lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.padding(28)
            }
            Divider()
            HStack {
                Text("TXT · MD · SRT сохранены").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if state.input == nil { Button("Указать исходную запись") { state.selectFile() } }
                if state.playing { Button { state.stopPlayback() } label: { Image(systemName: "stop.fill") }.help("Остановить прослушивание") }
                Button("Копировать текст") { state.copyText() }
                Button("Открыть папку") { state.showFolder() }.buttonStyle(.borderedProminent)
            }.padding(18)
        }
    }

    private func speakerColor(_ speaker: Int) -> Color {
        let colors: [Color] = [accent, .purple, .teal, .orange, .pink, .indigo, .brown, .green]
        return colors[(speaker - 1) % colors.count]
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = state, state.running else { return .terminateNow }
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
            }
    }
}
