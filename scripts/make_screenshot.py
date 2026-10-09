# -*- coding: utf-8 -*-
from pathlib import Path
import subprocess
r=Path(__file__).resolve().parents[1]
build=r/'build/readme-preview'; build.mkdir(parents=True,exist_ok=True)
source=(r/'macos/LocalTranscriber.swift').read_text()
# Демопредпросмотр не открывает менеджер моделей и не запускает распознавание.
source=source.replace('.onAppear { if !state.modelReady { state.showModels = true } }', '')
(build/'Controller.swift').write_text(source[:source.index('@main\nstruct LocalTranscriberApp')])
fixture='''import SwiftUI
import AppKit

@main
struct ReadmeScreenshot {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .aqua)
        let state = AppModel()
        state.model = "gigaam"; state.diarize = true; state.speakerCount = 2
        state.expectedLanguage = "ru"
        state.input = URL(fileURLWithPath: "/tmp/Обсуждение проекта.m4a")
        state.names = ["1":"Алексей", "2":"Марина"]
        state.transcript = Transcript(version: 2, source: "Обсуждение проекта.m4a", model: "GigaAM v3 E2E",
            duration: 165, diarized: true, speakerCount: 2, requestedSpeakers: 2, names: state.names,
            segments: [
                Segment(start:0,end:18,text:"Давайте обсудим план. Нам нужно подготовить встречу и собрать предложения команды.",speaker:1,segmentID:"demo-1"),
                Segment(start:20,end:38,text:"Я предлагаю начать с короткого списка задач. Так каждому будет понятно, за что он отвечает.",speaker:2,segmentID:"demo-2"),
                Segment(start:40,end:59,text:"Хорошо. А после встречи сохраним договорённости и разошлём участникам готовый текст.",speaker:1,segmentID:"demo-3"),
                Segment(start:62,end:83,text:"Да, и отметим сроки. Первый вариант можно подготовить к пятнице.",speaker:2,segmentID:"demo-4"),
                Segment(start:86,end:110,text:"Тогда я займусь планом встречи, а ты соберёшь вопросы от команды.",speaker:1,segmentID:"demo-5"),
                Segment(start:112,end:165,text:"Договорились. Если появятся дополнения, внесём их в общий документ.",speaker:2,segmentID:"demo-6")],
            processingSeconds:5,expectedLanguage:"ru",title:"Обсуждение проекта")
        state.updatePlaybackTime(46)
        let root = VStack(spacing:0) {
            HStack(spacing:8) {
                Circle().fill(Color(red:1,green:0.37,blue:0.34)).frame(width:12,height:12)
                Circle().fill(Color(red:1,green:0.75,blue:0.25)).frame(width:12,height:12)
                Circle().fill(Color(red:0.25,green:0.78,blue:0.31)).frame(width:12,height:12)
                Text("Голоса").font(.system(size:13,weight:.medium)).padding(.leading,8)
                Spacer()
            }.padding(.horizontal,18).frame(height:38).background(Color(nsColor:.windowBackgroundColor))
            Divider()
            ContentView().environmentObject(state)
        }.frame(width:1240,height:940).background(Color.white).environment(\\.controlActiveState,.active).environment(\\.colorScheme,.light)
        let host = NSHostingView(rootView:root)
        host.frame = NSRect(x:0,y:0,width:1240,height:940)
        let window = NSWindow(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView = host
        // Окно не показывается и не получает пользовательский ввод.
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until:Date().addingTimeInterval(1))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) else { exit(1) }
        host.cacheDisplay(in:host.bounds,to:bitmap)
        let canvas = NSImage(size:host.bounds.size)
        canvas.lockFocus()
        NSColor.white.setFill(); host.bounds.fill()
        bitmap.draw(in:host.bounds)
        canvas.unlockFocus()
        guard let data = canvas.tiffRepresentation, let flattened = NSBitmapImageRep(data:data),
              let png = flattened.representation(using:.png,properties:[:]) else { exit(1) }
        do { try png.write(to:URL(fileURLWithPath:CommandLine.arguments[1])) }
        catch { fputs("Не удалось сохранить изображение\\n",stderr); exit(1) }
        print("Изображение интерфейса с вымышленным диалогом сохранено.")
    }
}
'''
(build/'Screenshot.swift').write_text(fixture)
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-target','arm64-apple-macos14.0','-module-cache-path',str(build/'swift-cache'),str(build/'Controller.swift'),str(build/'Screenshot.swift'),*[str(p) for p in (r/'macos').glob('*.swift') if p.name!='LocalTranscriber.swift'],'-o',str(build/'ReadmePreview')],check=True)
output=r/'assets/screenshots/app-overview.png';output.parent.mkdir(parents=True,exist_ok=True)
subprocess.run([str(build/'ReadmePreview'),str(output)],check=True)

# Сохраняется только PNG; промежуточная сборка не нужна пользователям.
import shutil
shutil.rmtree(build,ignore_errors=True)
