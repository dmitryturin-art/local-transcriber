import Foundation

@main
struct ControllerSmokeTest {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { fatalError("Укажите аудио и каталог результата") }
        let state = AppModel()
        state.input = URL(fileURLWithPath: args[1])
        state.output = URL(fileURLWithPath: args[2], isDirectory: true)
        state.diarize = true
        state.speakerCount = 2
        state.model = args.count > 3 ? args[3] : "gigaam"
        state.start()
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
        for name in ["transcript.txt", "transcript.md", "transcript.srt", "transcript.json"] {
            let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            precondition(text.contains("Дмитрий") && text.contains("Юрий"))
        }
        state.loadResult(folder.appendingPathComponent("transcript.json"))
        precondition(state.transcript?.names["2"] == "Дмитрий")
        print("Контроллер окна: обработка, получение результата, переименование и повторное открытие — OK")
    }
}
