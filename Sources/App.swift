import SwiftUI
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import ServiceManagement
import Darwin
import CoreGraphics

struct DisplayChoice: Identifiable { let id: CGDirectDisplayID; let name: String; let width: Int; let height: Int }
// Stream lifecycle is owned by MainActor; encoder state is confined to queue.
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var stream: SCStream?
    let queue = DispatchQueue(label: "capture.jpeg", qos: .userInteractive)
    let context = CIContext(options: [.cacheIntermediates:false])
    var onFrame: ((Data, Double) -> Void)?
    var gate: DispatchSemaphore?
    var onError: ((String) -> Void)?
    var quality = 0.82
    var last = Date.distantPast
    func begin(_ display: SCDisplay, showsCursor: Bool) async throws {
        let config = SCStreamConfiguration()
        config.width = 1024; config.height = 768
        config.captureResolution = .best
        config.minimumFrameInterval = CMTime(value:1,timescale:60)
        config.queueDepth = 3; config.showsCursor = showsCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let s = SCStream(filter: SCContentFilter(display:display,excludingWindows:[]), configuration:config, delegate:self)
        try s.addStreamOutput(self,type:.screen,sampleHandlerQueue:queue)
        stream = s
        try await s.startCapture()
    }
    func stop() async { try? await stream?.stopCapture(); stream = nil }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onError?(error.localizedDescription) }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixel = buffer.imageBuffer else { return }
        guard CVPixelBufferGetWidth(pixel) == 1024, CVPixelBufferGetHeight(pixel) == 768 else { onError?("Неверный размер буфера: \(CVPixelBufferGetWidth(pixel))×\(CVPixelBufferGetHeight(pixel))"); return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]], let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue else { return }
        guard let gate = gate, gate.wait(timeout: .now()) == .success else {return}
        var handedOff = false
        defer { if !handedOff {gate.signal()} }
        let started = ProcessInfo.processInfo.systemUptime
        let ci = CIImage(cvPixelBuffer:pixel)
        guard let cg = context.createCGImage(ci,from:ci.extent) else { return }
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data,UTType.jpeg.identifier as CFString,1,nil) else { return }
        CGImageDestinationAddImage(dst,cg,[kCGImageDestinationLossyCompressionQuality:quality] as CFDictionary)
        if CGImageDestinationFinalize(dst) { handedOff = true; onFrame?(data as Data, (ProcessInfo.processInfo.systemUptime-started)*1000) }
    }
}
@MainActor final class Model: ObservableObject {
    @Published var displays: [DisplayChoice] = []
    @Published var name = UserDefaults.standard.string(forKey:"displayName") ?? ""
    @Published var ip = ""
    @Published var addresses: [String] = []
    @Published var status = "Остановлено"
    @Published var stats = "Нет измерений на iPad"
    @Published var log = ""
    @Published var maximum = UserDefaults.standard.object(forKey:"maximumQuality") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(maximum,forKey:"maximumQuality")
            server.setMaximum(maximum)
        }
    }
    @Published var systemCursor = UserDefaults.standard.bool(forKey:"systemCursor") {
        didSet { UserDefaults.standard.set(systemCursor,forKey:"systemCursor") }
    }
    @Published var running = false
    @Published var code = ""
    let server = Server(), capture = Capture()
    var timer: Timer?
    var activeID: CGDirectDisplayID?
    var refreshing = false
    var generation = 0
    var accessGate = CaptureAccessGate()
    init() {
        server.page = (try? String(contentsOf:Bundle.main.url(forResource:"index",withExtension:"html") ?? URL(fileURLWithPath:"Web/index.html"))) ?? ""
        code = server.code
        server.onStats = { [weak self] s in Task { @MainActor in self?.stats = s } }
        let encoder = capture
        server.onQuality = { q in encoder.queue.async {encoder.quality = q} }
        server.setMaximum(maximum)
        capture.gate = server.frameGate
        capture.onFrame = { [weak server] data, ms in server?.publish(data, encodeMilliseconds:ms) }
        capture.onError = { [weak self] error in Task { @MainActor in guard let self = self else {return}; await self.pauseAfterFailure(error) } }
        addresses = Self.lanAddresses(); ip = addresses.first ?? ""
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval:3,repeats:true) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
        if UserDefaults.standard.bool(forKey:"resume") { Task { await start() } }
    }
    func note(_ s: String) { status = s; log = String((log + "\n\(Date()): \(s)").suffix(12000)) }
    func refresh() async {
        // NSScreen enumeration does not ask for screen-recording access.
        displays = NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {return nil}
            return DisplayChoice(id:id, name:screen.localizedName, width:Int(screen.frame.width), height:Int(screen.frame.height))
        }
        guard running else {return}
        guard accessGate.permitsEnumeration(preflight: {CGPreflightScreenCaptureAccess()}) else {
            await pauseAfterFailure("Нет доступа к записи экрана. Нажмите «Доступ к экрану…», затем перезапустите приложение.")
            return
        }
        guard !refreshing else { return }; refreshing = true; defer {refreshing = false}
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)

            guard running, !accessGate.paused else {return}
            let matches = displays.filter { $0.name == name }
            guard matches.count == 1, let chosen = matches.first, let d = content.displays.first(where:{$0.displayID == chosen.id}) else {
                if activeID != nil { await stopCapture(); activeID = nil }
                note(matches.count > 1 ? "Несколько экранов с таким именем — задайте уникальное имя в BetterDisplay" : "Ожидание экрана «\(name)»…"); return
            }
            guard CGDisplayMirrorsDisplay(d.displayID) == kCGNullDirectDisplay else { note("Экран дублируется. Выберите расширение в настройках macOS."); return }
            if activeID != d.displayID {
                await stopCapture()
                guard let mode = CGDisplayCopyDisplayMode(d.displayID), mode.pixelWidth >= 1024, mode.pixelHeight >= 768 else { note("Источник меньше 1024×768 физических пикселей. Проверьте режим BetterDisplay."); return }
                let g = generation
                try await capture.begin(d, showsCursor:systemCursor)
                if !running || g != generation { await stopCapture(); return }
                let bounds = systemCursor ? nil : CGDisplayBounds(d.displayID)
                let srv = server
                srv.queue.async {srv.cursorBounds = bounds}
                activeID = d.displayID; note("Захват 1024×768 · \(chosen.name) · источник \(mode.pixelWidth)×\(mode.pixelHeight)")
            }

        } catch { await pauseAfterFailure("Захват приостановлен: \(error.localizedDescription). Повторы отключены. Проверьте доступ и нажмите «Начать».") }
    }
    func pauseAfterFailure(_ message: String) async {
        accessGate.failed()
        generation += 1
        running = false
        server.stop()
        activeID = nil
        await stopCapture()
        note(message)
    }
    func requestAccess() {
        // Never called by initialization, a timer or an automatic retry.
        if CGPreflightScreenCaptureAccess() {
            accessGate.userRetry()
            note("macOS подтверждает доступ. Нажмите «Начать». Если отказ повторится — перезапустите приложение.")
        } else {
            _ = CGRequestScreenCaptureAccess()
            note("Разрешите запись экрана для этой копии приложения, затем полностью закройте и откройте её заново.")
            if let url = URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
        }
    }
    func stopCapture() async {
        await capture.stop()
        let srv = server
        srv.queue.async {srv.latest = nil; srv.cursorBounds = nil}
    }
    func start() async {
        guard !running, !refreshing else {return}
        guard !name.isEmpty else {note("Выберите экран для трансляции."); return}
        accessGate.userRetry()
        guard accessGate.permitsEnumeration(preflight: {CGPreflightScreenCaptureAccess()}) else {
            note("Нет доступа к записи экрана. Нажмите «Доступ к экрану…». Если переключатель уже включён — полностью закройте и заново откройте приложение.")
            return
        }
        guard addresses.contains(ip) else { note("Выберите локальный IPv4 адрес Wi-Fi/Ethernet"); return }
        do { try server.start(ip:ip); running = true; UserDefaults.standard.set(name,forKey:"displayName"); UserDefaults.standard.set(true,forKey:"resume"); note("Сервер \(ip):8766. Ожидание экрана…"); await refresh() } catch { note(error.localizedDescription) }
    }
    func stop() async { generation += 1; running = false; UserDefaults.standard.set(false,forKey:"resume"); server.stop(); await stopCapture(); activeID = nil; note("Остановлено") }
    func login() { do { try SMAppService.mainApp.register(); note("Автозапуск: проверьте разрешение в объектах входа") } catch { note(error.localizedDescription) } }
    func resetPairs() {
        let srv = server
        srv.queue.async {
            srv.token = UUID().uuidString + UUID().uuidString
            UserDefaults.standard.set(srv.token,forKey:"lanToken")
            for id in Array(srv.peers.keys) { srv.close(id) }
        }
        note("Сохранённые подключения отозваны. Введите код на iPad заново.")
    }
    func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "iPadLAN-diagnostics.txt"
        if panel.runModal() == .OK, let url = panel.url { try? ("\(status)\n\(stats)\nЭкраны: \(displays.map { "\($0.name): \($0.width)×\($0.height)" })\n\(log)").write(to:url,atomically:true,encoding:.utf8) }
    }
    static func lanAddresses() -> [String] {
        var ptr: UnsafeMutablePointer<ifaddrs>?; guard getifaddrs(&ptr) == 0 else {return []}; defer {freeifaddrs(ptr)}
        var p = ptr, result: [String] = []
        while let current = p { defer {p = current.pointee.ifa_next}; let i = current.pointee
            guard String(cString:i.ifa_name).hasPrefix("en"), let a = i.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) else {continue}
            var host = [CChar](repeating:0,count:Int(NI_MAXHOST))
            if getnameinfo(a,socklen_t(a.pointee.sa_len),&host,socklen_t(host.count),nil,0,NI_NUMERICHOST) == 0 {result.append(String(cString:host))}
        }; return result.sorted()
    }
}
struct Content: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("iPad LAN Display 0.3.1").font(.largeTitle)
            Text("Передача экрана по Wi‑Fi · 1024 × 768")
            Picker("Экран по имени",selection:$m.name) { Text(m.name.isEmpty ? "Выберите экран…" : (m.displays.contains(where:{$0.name == m.name}) ? m.name : m.name + " (ожидание)")).tag(m.name); ForEach(m.displays.filter{$0.name != m.name}) { d in Text("\(d.name) — \(d.width)×\(d.height)").tag(d.name) } }.disabled(m.running)
            Picker("Локальный адрес",selection:$m.ip) { ForEach(m.addresses,id:\.self) { Text($0).tag($0) } }.disabled(m.running)
            Text("Адрес для браузера: http://\(m.ip):8766").textSelection(.enabled)
            Text("Код подключения: \(m.code)").font(.title2).monospacedDigit()
            HStack { Button(m.running ? "Остановить" : "Начать") { Task { if m.running {await m.stop()} else {await m.start()} } }; Button("Обновить") { m.addresses = Model.lanAddresses(); Task {await m.refresh()} }; Button("Автозапуск") {m.login()}; Button("Диагностика…") {m.export()}; Button("Сбросить пары") { m.resetPairs() } }
            Button("Доступ к экрану…") {m.requestAccess()}
            Toggle("Максимум: JPEG 95%, до 60 FPS",isOn:$m.maximum)
            Toggle("Системный курсор macOS",isOn:$m.systemCursor).disabled(m.running)
            Text("По умолчанию — быстрая стрелка. Чтобы сменить режим, остановите трансляцию.").font(.caption)
            Text(m.status).foregroundStyle(.blue).fixedSize(horizontal:false,vertical:true)
            Text(m.stats).font(.system(.body,design:.monospaced)).fixedSize(horizontal:false,vertical:true)
            Text("Предел захвата — 60 FPS; фактическая частота зависит от iPad и сети. JPEG 95% в режиме «Максимум», 70–90% в адаптивном. ACK — доставка и декодирование, а не задержка до экрана.").font(.caption).fixedSize(horizontal:false,vertical:true)
            ScrollView { Text(m.log).font(.system(.caption,design:.monospaced)).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled) }.frame(height:120)
            HStack(spacing: 4) {
                Text("Development by")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("SVX")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Development by SVX")
            .frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(24).frame(width:710)
    }
}
final class DisplayAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct DisplayMenu: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Открыть окно") {
            openWindow(id:"main")
            NSApp.activate(ignoringOtherApps:true)
        }
        Button(model.running ? "Остановить трансляцию" : "Начать трансляцию") {
            Task {
                if model.running {
                    await model.stop()
                } else {
                    await model.start()
                    if !model.running {
                        openWindow(id:"main")
                        NSApp.activate(ignoringOtherApps:true)
                    }
                }
            }
        }
        Divider()
        Text("Development by SVX")
        Button("Выйти из iPad LAN Display") { NSApp.terminate(nil) }
    }
}

@main struct DisplayApp: App {
    @NSApplicationDelegateAdaptor(DisplayAppDelegate.self) private var delegate
    @StateObject private var model = Model()

    var body: some Scene {
        Window("iPad LAN Display",id:"main") { Content(m:model) }
        MenuBarExtra {
            DisplayMenu(model:model)
        } label: {
            Label("iPad LAN Display", systemImage:model.running ? "display" : "display.slash")
        }
        .menuBarExtraStyle(.menu)
    }
}
