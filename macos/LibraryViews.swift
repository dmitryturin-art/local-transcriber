import SwiftUI
import AppKit

struct LibraryEntry: Identifiable {
    let url: URL
    let title: String
    let model: String
    let duration: Double
    let date: Date
    var id: String { url.path }
}

enum TranscriptLibrary {
    static func entries(in folder: URL) -> [LibraryEntry] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return folders.compactMap { directory in
            let url = directory.appendingPathComponent("transcript.json")
            guard let data = try? Data(contentsOf: url), let doc = try? decoder.decode(Transcript.self, from: data) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return LibraryEntry(url: url, title: doc.source, model: doc.model, duration: doc.duration, date: date)
        }.sorted { $0.date > $1.date }
    }
    static func trash(_ entry: LibraryEntry) throws {
        // Удаляем только известные результаты, никогда исходную запись или посторонние файлы.
        let folder = entry.url.deletingLastPathComponent()
        let names = ["transcript.json", "transcript.txt", "transcript.md", "transcript.srt", "transcript.no-speakers.txt", "transcript.no-speakers.md", "transcript.no-speakers.srt", "transcript.original.json", "transcript.original.txt", "transcript.original.md", "transcript.original.srt", "transcript.original.no-speakers.txt", "transcript.original.no-speakers.md", "transcript.original.no-speakers.srt", "voiceprints.npz"]
        for name in names {
            let file = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.trashItem(at: file, resultingItemURL: nil) }
        }
        if (try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty) == true { try? FileManager.default.removeItem(at: folder) }
    }
}

final class LibraryState: ObservableObject {
    @Published var entries: [LibraryEntry] = []
    @Published var query = ""
    @Published var pending: LibraryEntry?
}

struct TranscriptLibraryPanel: View {
    @ObservedObject var state: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var library = LibraryState()
    private var filtered: [LibraryEntry] { library.entries.filter { library.query.isEmpty || $0.title.localizedCaseInsensitiveContains(library.query) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Мои транскрипции").font(.title2.bold())
            Text("Результаты в выбранной папке сохранения. Исходные аудиозаписи при удалении остаются.").font(.caption).foregroundStyle(.secondary)
            TextField("Поиск по названию", text: $library.query)
            List(filtered) { entry in
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.title).font(.headline)
                        Text("\(entry.model) · \(timecode(entry.duration)) · \(entry.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Открыть") { state.openLibraryResult(entry.url) }
                    Button { NSWorkspace.shared.open(entry.url.deletingLastPathComponent()) } label: { Image(systemName: "folder") }.help("Показать файлы")
                    Button { library.pending = entry } label: { Image(systemName: "trash") }.help("Удалить результаты в Корзину")
                }.padding(.vertical, 5)
            }
            if library.entries.isEmpty { Text("В этой папке пока нет транскрипций. Другой результат можно открыть через «Открыть JSON…».").foregroundStyle(.secondary) }
            HStack {
                Button("Обновить") { reload() }
                Button("Открыть JSON…") { dismiss(); state.openResult() }
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 780, height: 540).onAppear { reload() }
        .alert("Удалить транскрипцию в Корзину?", isPresented: Binding(get: { library.pending != nil }, set: { if !$0 { library.pending = nil } })) {
            Button("Отмена", role: .cancel) { library.pending = nil }
            Button("Удалить", role: .destructive) {
                guard let entry = library.pending else { return }
                if state.resultFolder == entry.url.deletingLastPathComponent() && state.hasUnsavedChanges {
                    state.error = "Сначала сохраните или отмените правки открытой транскрипции."; library.pending = nil; return
                }
                do {
                    try TranscriptLibrary.trash(entry)
                    if state.resultFolder == entry.url.deletingLastPathComponent() { state.stopPlayback(); state.transcript = nil; state.resultFolder = nil }
                    reload()
                } catch { state.error = "Не удалось удалить результат: \(error.localizedDescription)" }
                library.pending = nil
            }
        } message: { Text(library.pending?.title ?? "") }
    }
    private func reload() { library.entries = TranscriptLibrary.entries(in: state.output) }
}

struct HelpPanel: View {
    @Environment(\.dismiss) private var dismiss
    private let guide = """
    1. Выберите запись и модель. Для диалога включите разделение по спикерам и укажите число участников, если оно известно. Нажмите «Расшифровать». Интернет нужен только для загрузки моделей.

    2. Имена спикеров можно вписать после обработки. «Редактировать» позволяет менять текст и назначать спикера отдельной реплике. Enter в поле имени не запускает распознавание. «Сохранить правки» обновляет файлы без повторной обработки аудио.

    3. Плей у времени реплики проигрывает исходную запись с этой отметки. Ползунок внизу перемещает позицию и подсвечивает соответствующую реплику. Флажок «Следовать за звуком» включает автопрокрутку; при редактировании она приостанавливается. Сначала появляется «Подготовка звука…», затем кнопка стоп внизу. Если исходная запись недоступна, выберите её снова. Если звук не слышен, проверьте громкость и устройство вывода macOS.

    4. Значок с галочкой справа — ваша ручная отметка «Проверено мной». Ставьте её после проверки текста и спикера. Такая реплика исчезает из фильтра «Требуют проверки». Отметка не обучает модель и не подтверждает точность автоматически; её можно снять.

    5. «Голос неуверенно» означает сомнение в спикере. «Одновременная речь» — голоса могли пересекаться. «Спикер не определён» — программа не смогла уверенно назначить голос. Проверьте такие места вручную. Автоматическая диаризация может ошибаться даже при правильном числе участников.

    6. «Спикеры» позволяет объединить номера или пересчитать распределение голосов. Объединение — ручная правка. Пересчёт голосов запускает отдельную обработку и может изменить назначения; текст не распознаётся заново. Только «Расшифровать» запускает полное распознавание.

    7. «Найти и заменить» исправляет повторяющиеся слова с предварительным просмотром. «Словарь» хранит правила замен. Отмена и повтор правок доступны в редакторе.

    8. Результат сохраняется в TXT, Markdown, SRT и JSON. Одновременно создаются версии с именами спикеров и без них. Флажок «Спикеры» в просмотре только меняет показ текста. JSON нужен для повторного открытия и редактирования.

    9. «Мои транскрипции» показывает результаты выбранной папки сохранения: поиск, открытие, показ файлов и удаление в Корзину. Исходное аудио не удаляется. Результаты из другой папки можно открыть через «Открыть JSON…».

    10. В «Управлении моделями» можно скачать, импортировать или удалить модель. После удаления её можно скачать снова. Аудио и транскрипции обрабатываются локально.
    """
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Как пользоваться «Голоса»").font(.title2.bold())
            ScrollView { Text(guide).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            HStack { Spacer(); Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 720, height: 620)
    }
}
