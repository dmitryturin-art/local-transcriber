import SwiftUI

struct SpeakerToolsPanel: View {
    @ObservedObject var state: AppModel
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("Распределение спикеров").font(.title2).fontWeight(.semibold)
            if let document = state.transcript, document.speakerCount > 1 {
                Text("Объединить группы одного человека").font(.headline)
                HStack {
                    Picker("Из группы",selection:$state.mergeFrom) { ForEach(1...document.speakerCount,id:\.self) { i in Text(state.label(i)).tag(i) } }
                    Picker("В группу",selection:$state.mergeInto) { ForEach(1...document.speakerCount,id:\.self) { i in Text(state.label(i)).tag(i) } }
                }
                Text("Меняются все реплики группы. Если ошибочны отдельные реплики, исправьте их в редакторе. Объединение можно отменить.").font(.caption).foregroundStyle(.secondary)
                Button("Объединить") { state.mergeSpeakers() }.disabled(state.mergeFrom == state.mergeInto)
                Divider()
            }
            Text("Пересчитать по голосам").font(.headline)
            Picker("Сколько участников",selection:$state.reclusterCount) {
                Text("Авто").tag(0); ForEach(1...8,id:\.self) { n in Text("\(n)").tag(n) }
            }
            Text("Текст и таймкоды сохранятся. Распределение можно отменить; имена нужно проверить заново. Для старых результатов нужна исходная запись.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Закрыть") { state.showSpeakerTools = false }.keyboardShortcut(.cancelAction)
                Spacer(); Button("Пересчитать голоса") { state.recalculateSpeakers() }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width:620)
    }
}

struct ModelsPanel: View {
    @ObservedObject var state: AppModel
    @ObservedObject var manager: ModelManager
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("Модели на этом Mac").font(.title2).fontWeight(.semibold)
            Text("Загрузите одну модель, вторую можно добавить позже. После загрузки распознавание работает без интернета.").font(.subheadline).foregroundStyle(.secondary)
            ForEach(["gigaam","parakeet"],id:\.self) { id in
                HStack {
                    VStack(alignment:.leading,spacing:5) {
                        Text(id == "gigaam" ? "GigaAM v3 E2E" : "Parakeet v3 Q8_0").font(.headline)
                        Text((manager.available(id) ? "Готова · " : "Не загружена · ")+manager.sizeLabel(id)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if manager.available(id) {
                        Button(state.model == id ? "Выбрана" : "Выбрать") { state.model = id }.disabled(state.model == id || state.running)
                        Button { manager.remove(id) } label: { Image(systemName:"trash") }.disabled(manager.busy || state.running)
                    } else { Button("Загрузить") { manager.download(id) }.disabled(manager.busy || state.running) }
                }.padding(14).background(Color(nsColor:.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:10))
            }
            Text("Компоненты диаризации загружаются один раз для обеих моделей.").font(.caption).foregroundStyle(.secondary)
            if manager.busy {
                ProgressView(value:manager.progress,total:1)
                HStack { Text(manager.message).font(.caption); Spacer(); Button("Приостановить") { manager.pause() } }
            } else { Text(manager.message).font(.caption).foregroundStyle(.secondary) }
            if let failure = manager.failure { Text(failure).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            HStack {
                Button("Импортировать из папки") { manager.chooseImportFolder() }.disabled(manager.busy || state.running)
                Spacer(); Button("Закрыть") { state.showModels = false }.keyboardShortcut(.cancelAction)
            }
            Text(manager.directory.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(24).frame(width:620)
    }
}
