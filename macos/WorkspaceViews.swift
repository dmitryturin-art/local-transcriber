import SwiftUI
import AppKit

// Совместимость с результатами предыдущих версий без повторного распознавания.
enum ServiceFiles {
    static let folderName = "Служебные данные"
    static let names = ["transcript.json", "voiceprints.npz", "transcript.original.json", "transcript.original.txt", "transcript.original.md", "transcript.original.srt", "transcript.original.no-speakers.txt", "transcript.original.no-speakers.md", "transcript.original.no-speakers.srt"]
    static func directory(in folder: URL) -> URL { folder.appendingPathComponent(folderName, isDirectory: true) }
    static func resultFolder(for document: URL) -> URL {
        let parent = document.deletingLastPathComponent()
        return parent.lastPathComponent == folderName ? parent.deletingLastPathComponent() : parent
    }
    static func file(_ name: String, in folder: URL) -> URL {
        let nested = directory(in: folder).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: nested.path) ? nested : folder.appendingPathComponent(name)
    }
    static func documentURL(in folder: URL) -> URL { file("transcript.json", in: folder) }
    static func organize(in folder: URL) throws {
        let fm = FileManager.default, service = directory(in: folder)
        try fm.createDirectory(at: service, withIntermediateDirectories: true)
        for name in names {
            let old = folder.appendingPathComponent(name), new = service.appendingPathComponent(name)
            if fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) { try fm.moveItem(at: old, to: new) }
        }
    }
}

enum SearchHighlight {
    static func ranges(_ text: String, query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let source = text as NSString
        var result: [NSRange] = [], rest = NSRange(location: 0, length: source.length)
        while rest.length > 0 {
            let match = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: rest)
            guard match.location != NSNotFound && match.length > 0 else { break }
            result.append(match)
            rest = NSRange(location: NSMaxRange(match), length: source.length - NSMaxRange(match))
        }
        return result
    }
    static func text(_ text: String, query: String) -> AttributedString {
        var result = AttributedString(text)
        for match in ranges(text, query: query) {
            guard let range = Range(match, in: text),
                  let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[start..<end].backgroundColor = Color.yellow.opacity(0.45)
        }
        return result
    }
}

struct SettingsPanel: View {
    @ObservedObject var state: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Настройки").font(.title2.bold())
            Text("Папка сохранения").font(.headline)
            Text("Новые результаты автоматически сохраняются сюда. В «Моих транскрипциях» показаны записи из этой папки.").font(.subheadline).foregroundStyle(.secondary)
            Text(state.output.path).textSelection(.enabled).font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor)).cornerRadius(8)
            Button("Выбрать папку сохранения…") { state.selectOutput() }.disabled(state.running)
            Text("Смена папки не перемещает ранее созданные результаты. Их можно открыть через меню «Файл». Аудиозаписи остаются на своих местах.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("Управление моделями…") { dismiss(); DispatchQueue.main.async { state.showModels = true } }.disabled(state.running)
            HStack { Spacer(); Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 580)
    }
}

struct ExportPanel: View {
    @ObservedObject var state: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Экспорт транскрипции").font(.title2.bold())
            Text(state.transcript?.displayTitle ?? "").font(.headline)
            Picker("Формат", selection: $state.exportFormat) { Text("TXT — обычный текст").tag("txt"); Text("Markdown").tag("md"); Text("SRT — субтитры").tag("srt") }
            Picker("Вариант", selection: $state.exportSpeakers) { Text("По спикерам").tag(true); Text("Без спикеров").tag(false) }
            Text("Временные метки сохраняются в обоих вариантах. Без спикеров остаются только текст и время. Экспорт включает текущие правки; сохранение документа выполняется отдельно.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Экспортировать…") { state.exportResult() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 520)
    }
}

enum RussianMenus {
    static let titles = ["File":"Файл", "Edit":"Правка", "View":"Вид", "Window":"Окно", "Help":"Справка", "Services":"Службы", "Close":"Закрыть окно", "Minimize":"Свернуть", "Zoom":"Увеличить", "Bring All to Front":"Все окна на передний план", "Cut":"Вырезать", "Copy":"Копировать", "Paste":"Вставить", "Paste and Match Style":"Вставить с сохранением стиля", "Select All":"Выбрать всё", "Delete":"Удалить", "Undo":"Отменить", "Redo":"Повторить", "Hide Others":"Скрыть остальные", "Show All":"Показать все", "Enter Full Screen":"На весь экран", "Exit Full Screen":"Выйти из полноэкранного режима", "Show Toolbar":"Показать панель инструментов", "Hide Toolbar":"Скрыть панель инструментов", "Show Tab Bar":"Показать панель вкладок", "Hide Tab Bar":"Скрыть панель вкладок", "Show All Tabs":"Показать все вкладки", "Merge All Windows":"Объединить все окна", "Move Tab to New Window":"Перенести вкладку в новое окно", "Show Previous Tab":"Предыдущая вкладка", "Show Next Tab":"Следующая вкладка", "Spelling and Grammar":"Правописание", "Substitutions":"Замены", "Transformations":"Преобразования", "Speech":"Речь"]
    static func localize(_ menu: NSMenu?) {
        guard let menu = menu else { return }
        if let translated = titles[menu.title] { menu.title = translated }
        for item in menu.items {
            if let translated = titles[item.title] { item.title = translated }
            else if item.title.hasPrefix("About ") { item.title = "О программе «Голоса»" }
            else if item.title.hasPrefix("Quit ") { item.title = "Завершить «Голоса»" }
            else if item.title.hasPrefix("Hide ") && item.action == #selector(NSApplication.hide(_:)) { item.title = "Скрыть «Голоса»" }
            localize(item.submenu)
        }
    }
}
