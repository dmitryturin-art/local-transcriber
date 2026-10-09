import Foundation

@main
struct ModelManagerTests {
    static func main() throws {
        let args=CommandLine.arguments
        let resources=URL(fileURLWithPath:args[1])
        let folder=URL(fileURLWithPath:args[2])
        let source=URL(fileURLWithPath:args[3])
        let manager=ModelManager(directory:folder,resources:resources)
        manager.importFolder(source)
        let deadline=Date().addingTimeInterval(120)
        while manager.busy && Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.05)) }
        precondition(!manager.busy && manager.failure == nil,manager.failure ?? "Import timeout")
        precondition(manager.available("gigaam") && manager.available("parakeet"))
        let reused=ModelManager(directory:folder,resources:resources)
        precondition(reused.available("gigaam") && reused.available("parakeet"))
        print("Импорт обеих моделей, контрольные суммы и повторный запуск — OK")
        if args.count>4 {
            let catalog=manager.assets.filter { $0.path == "silero_vad.onnx" }
            let tiny=folder.appendingPathComponent("download-test")
            let fixture=folder.appendingPathComponent("catalog-test")
            try FileManager.default.createDirectory(at:fixture,withIntermediateDirectories:true)
            try JSONEncoder().encode(catalog).write(to:fixture.appendingPathComponent("model-catalog.json"))
            let network=ModelManager(directory:tiny,resources:fixture)
            network.download("gigaam")
            let end=Date().addingTimeInterval(90)
            while network.busy && Date()<end { RunLoop.current.run(until:Date().addingTimeInterval(0.05)) }
            precondition(!network.busy && network.failure == nil,network.failure ?? "Download timeout")
            precondition(FileManager.default.fileExists(atPath:tiny.appendingPathComponent("silero_vad.onnx").path))
            print("Реальная загрузка малого компонента из GitHub и SHA-256 — OK")
        }
    }
}
