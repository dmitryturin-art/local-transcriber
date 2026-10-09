import Foundation

// Провал проверки завершает процесс обычным кодом, без окна аварийного отчёта macOS.
func precondition(_ condition: @autoclosure () -> Bool) {
    if !condition() { fputs("Проверка контроллера не пройдена\n", stderr); exit(1) }
}
func fatalError(_ message: String) -> Never { fputs(message + "\n", stderr); exit(1) }

@main
struct ControllerSmokeTest {
    static func main() {
        do { try run() } catch { fputs("Ошибка проверки: \(error)\n", stderr); exit(1) }
    }
    static func run() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { fatalError("Укажите аудио и каталог результата") }
        let state = AppModel()
        state.input = URL(fileURLWithPath: args[1])
        state.output = URL(fileURLWithPath: args[2], isDirectory: true)
        state.diarize = true
        state.speakerCount = 2
        state.model = args.count > 3 ? args[3] : "gigaam"
        state.termRules = []; state.automaticDictionary = false
        state.start()
        if args.contains("--cancel") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            state.cancel()
            let deadline = Date().addingTimeInterval(20)
            while state.running && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            precondition(!state.running && state.error == nil && state.transcript == nil)
            print("Контроллер: отмена обработки — OK")
            return
        }
        let timeout = Date().addingTimeInterval(180)
        while state.running && Date() < timeout {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard !state.running, state.error == nil, let transcript = state.transcript,
              let folder = state.resultFolder else { fatalError(state.error ?? "Не пришёл результат") }
        precondition(transcript.speakerCount == 2)
        state.names = ["1": "Юрий", "2": "Дмитрий"]
        state.saveNames()
        precondition(state.error == nil)
        let start = state.transcript!.segments[0].start
        state.editText(0, "Редактор проверен: GigaAM.")
        state.findTerm = "GigaAM"; state.replaceTerm = "модель"; state.matchWholeWord = true
        state.replaceAll(); state.editSpeaker(0, 2); state.saveEdits()
        precondition(state.transcript!.segments[0].text == "Редактор проверен: модель.")
        precondition(state.transcript!.segments[0].start == start)
        for name in ["transcript.txt", "transcript.md", "transcript.srt", "transcript.json"] {
            let text = try String(contentsOf: (name == "transcript.json" ? ServiceFiles.documentURL(in: folder) : folder.appendingPathComponent(name)), encoding: .utf8)
            precondition(text.contains("Дмитрий") && text.contains("Юрий"))
        }
        state.loadResult(folder.appendingPathComponent("transcript.json"))
        precondition(state.transcript?.names["2"] == "Дмитрий")
        print("Контроллер окна: обработка, получение результата, переименование и повторное открытие — OK")
    }
}
