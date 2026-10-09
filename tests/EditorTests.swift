import Foundation

@main
struct EditorTests {
    static func main() throws {
        let domain = "local.voices.editor-tests"
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1
        }
        let (literal, count) = TextReplacement.apply("Гигам2 Гигам_сервис суперГигам 👋 ГИГАМ",
            find: "гигам", replacement: "$1\\путь", caseSensitive: false, wholeWord: true)
        check(count == 1 && literal.hasSuffix("$1\\путь"), "Границы русских слов, UTF-16 и буквальная вставка")
        let (_, exact) = TextReplacement.apply("Гигам гигам", find: "Гигам", replacement: "модель", caseSensitive: true, wholeWord: true)
        check(exact == 1, "Учитывать регистр")
        let (empty, zero) = TextReplacement.apply("текст", find: "", replacement: "x", caseSensitive: false, wholeWord: false)
        check(empty == "текст" && zero == 0, "Пустой поиск")
        let (special, specialCount) = TextReplacement.apply("API/v2? API/v2?", find: "API/v2?", replacement: "API", caseSensitive: true, wholeWord: false)
        check(special == "API API" && specialCount == 2, "Спецсимволы не являются регулярным выражением")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("editor-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let json = """
        {"version":1,"source":"demo.m4a","model":"test","duration":20,"diarized":true,
        "speaker_count":2,"requested_speakers":2,"names":{},"processing_seconds":1,
        "custom_meta":{"keep":7},"segments":[
        {"start":0,"end":4,"text":"iPhone: гигам и ГИГАМ","speaker":1,"uncertain":true,"similarity":0.54},
        {"start":3,"end":6,"text":"суперГигам Гигам2","speaker":2,"overlap":true},
        {"start":7,"end":10,"text":"Гигам","speaker":1}]}
        """
        let url = folder.appendingPathComponent("transcript.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        let state = AppModel()
        state.loadResult(url)
        check(state.error == nil && state.transcript?.segments.count == 3, "Открытие старого формата JSON")
        let originalID = state.transcript!.segments[0].id
        let originalTimes = state.transcript!.segments.map { [$0.start, $0.end] }
        state.editText(0, "iPhone: гигам и Гигам")
        state.editSpeaker(0, 2)
        check(state.transcript!.segments[0].id == originalID, "Редактирование не меняет идентификатор")
        state.undoEdit()
        check(state.transcript!.segments[0].speaker == 1 && state.transcript!.segments[0].text == "iPhone: гигам и Гигам", "Отмена смены спикера")
        state.undoEdit()
        check(state.transcript!.segments[0].text == "iPhone: гигам и ГИГАМ", "Отмена редактирования текста")
        state.redoEdit(); state.redoEdit()
        check(state.transcript!.segments[0].speaker == 2, "Повтор изменений")
        state.onlyIssues = true; state.markReviewed(0)
        check(state.visibleIndices == [1], "Навигация по непроверенным перекрытиям")
        state.onlyIssues = false
        state.findTerm = "гигам"; state.replaceTerm = "GigaAM"
        check(state.replacementPreview.count == 2 && state.replacementPreview.reduce(0) { $0 + $1.count } == 3, "Предпросмотр замен")
        check(state.transcript!.segments[0].text.contains("гигам"), "Предпросмотр не меняет текст")
        state.replaceAll()
        check(state.transcript!.segments[0].text == "iPhone: GigaAM и GigaAM", "Массовая замена")
        check(state.transcript!.segments.map { [$0.start, $0.end] } == originalTimes, "Таймкоды неизменны")
        state.addSpeaker(); state.renameSpeaker(3, "Новый участник"); state.editSpeaker(2, 3)
        check(state.transcript!.speakerCount == 3 && state.transcript!.segments[2].speaker == 3, "Добавление и назначение третьего спикера")
        state.saveEdits()
        check(state.error == nil && !state.hasUnsavedChanges, "Сохранение правок")
        for ext in ["txt", "md", "srt", "json"] {
            let text = try String(contentsOf: folder.appendingPathComponent("transcript.\(ext)"), encoding: .utf8)
            check(text.contains("GigaAM") && text.contains("Новый участник") && text.contains("iPhone"), "Согласованный экспорт \(ext)")
        }
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        check((stored["custom_meta"] as! [String: Any])["keep"] as! Int == 7, "Неизвестные поля JSON сохраняются")
        check((stored["segments"] as! [[String: Any]])[0]["similarity"] as! Double == 0.54, "Метаданные спикера сохраняются")
        let backupURL = folder.appendingPathComponent("transcript.original.json")
        let backup = try Data(contentsOf: backupURL)
        check(String(data: backup, encoding: .utf8) == json, "Исходная версия хранится без изменений")
        state.editSpeaker(0, 0); state.saveEdits()
        let noSpeaker = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        check((noSpeaker["segments"] as! [[String: Any]])[0]["speaker"] == nil, "Удаление спикера не восстанавливает старое поле")
        check(try Data(contentsOf: backupURL) == backup, "Повторное сохранение не перезаписывает исходник")
        state.loadResult(url)
        check(state.error == nil && state.transcript!.segments[2].speaker == 3, "Повторное открытие правок")
        state.restoreOriginal()
        check(state.transcript!.speakerCount == 2 && state.transcript!.segments[0].text == "iPhone: гигам и ГИГАМ", "Восстановление исходной версии")
        state.undoEdit()
        check(state.transcript!.speakerCount == 3, "Восстановление можно отменить")
        state.findTerm = "GigaAM"; state.replaceTerm = "Модель"; state.rememberReplacement()
        state.applyTermDictionary()
        check(state.transcript!.segments[0].text.contains("Модель"), "Локальный словарь")
        state.undoEdit()
        check(state.transcript!.segments[0].text.contains("GigaAM"), "Применение словаря можно отменить")
        state.undoEdit(); state.editText(0, "новая правка")
        check(!state.canRedoEdit, "Новая правка сбрасывает историю повтора")
        check(state.segmentText(500, id: originalID) == "", "Устаревший индекс редактора безопасен")
        let unchanged = state.transcript!.segments[0].text
        state.editText(0, "чужая реплика", id: "старый-документ")
        check(state.transcript!.segments[0].text == unchanged, "Старая привязка не меняет другую транскрипцию")
        if CommandLine.arguments.count > 1 {
            let source = URL(fileURLWithPath: CommandLine.arguments[1])
            let bytes = try Data(contentsOf: source)
            let large = AppModel(); large.loadResult(source)
            check(large.error == nil, "Открытие длинной транскрипции")
            large.findTerm = "я"; large.replaceTerm = "Я"; large.matchWholeWord = true
            let began = Date()
            let rows = large.replacementPreview
            large.replaceAll(); large.undoEdit()
            check(try Data(contentsOf: source) == bytes, "Проверка больших текстов не меняет исходный файл")
            print("Длинная транскрипция: \(large.transcript!.segments.count) реплик, \(rows.count) совпавших реплик, \(Date().timeIntervalSince(began)) с")
        }
        print("Редактор: \(checks) проверок — OK")
    }
}
