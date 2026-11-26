import Foundation
import Network
import Security
import CoreGraphics

final class Peer {
    let connection: NWConnection
    var buffer = Data()
    var ws = false
    var cursorOnly = false
    var separateCursor = false
    var busy = false
    var sent = Date()
    var deadline = Date()
    var lastVersion = 0
    var pumpScheduled = false
    var cursorSending = false
    var cursorPosition = ""
    var ackCount = 0
    var statsEpoch = Date()
    init(_ c: NWConnection) { connection = c }
}
// Mutable transport state is confined to queue after start; configuration is set before start.
final class Server: @unchecked Sendable {
    let queue = DispatchQueue(label: "lan.server")
    var listener: NWListener?
    var heartbeat: DispatchSourceTimer?
    var cursorTimer: DispatchSourceTimer?
    var cursorBounds: CGRect?
    var latestVersion = 0
    var encodeMS = 0.0
    var lastStats = Date.distantPast
    var peers: [UUID: Peer] = [:]
    var token: String
    init(persist: Bool = true) {
        token = (persist ? UserDefaults.standard.string(forKey:"lanToken") : nil) ?? (UUID().uuidString + UUID().uuidString)
        if persist { UserDefaults.standard.set(token,forKey:"lanToken") }
    }
    let frameGate = DispatchSemaphore(value: 1)
    var code = String(Int.random(in: 10000000...99999999))
    var attempts = 0
    var window = Date()
    var latest: Data?
    var latestAt = Date.distantPast
    var adaptive = Adaptive()
    var maximum = false
    var quality: Double { maximum ? 0.95 : adaptive.quality }
    var targetFPS: Double { maximum ? 60 : adaptive.fps }

    func setMaximum(_ enabled: Bool) {
        queue.async {
            self.maximum = enabled
            self.onQuality?(self.quality)
        }
    }
    var onStats: ((String) -> Void)?
    var onQuality: ((Double) -> Void)?
    var page = ""
    var hasReceivedFrame = false
    func start(ip: String, port: UInt16 = 8766) throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls:nil, tcp:tcp)
        guard let address = IPv4Address(ip), let localPort = NWEndpoint.Port(rawValue:port) else {throw NSError(domain:"LAN",code:1)}
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(address), port:localPort)
        let l = try NWListener(using: params)
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] state in self?.onStats?("Сервер: \(state)") }
        l.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now()+2, repeating:2)
        timer.setEventHandler { [weak self] in
            guard let self = self else {return}
            for (id,p) in Array(self.peers) where p.ws {
                if p.busy { if Date().timeIntervalSince(p.sent) > 4 {self.close(id)}; continue }
                p.connection.send(content: wsFrame(Data("idle".utf8),opcode:1), completion:.contentProcessed { _ in })
            }
        }
        heartbeat = timer; timer.resume()
        let cursor = DispatchSource.makeTimerSource(queue:queue)
        cursor.schedule(deadline:.now(), repeating:.milliseconds(8), leeway:.milliseconds(1))
        cursor.setEventHandler { [weak self] in self?.sendCursor() }
        cursorTimer = cursor; cursor.resume()
    }
    func stop() { queue.async { self.cursorTimer?.cancel(); self.cursorTimer = nil; self.cursorBounds = nil; self.heartbeat?.cancel(); self.heartbeat = nil; self.listener?.cancel(); self.listener = nil; for p in self.peers.values { p.connection.cancel() }; self.peers.removeAll(); self.latest = nil } }
    func accept(_ c: NWConnection) {
        guard peers.count < 8 else { c.cancel(); return }
        let id = UUID(), p = Peer(c); peers[id] = p
        c.stateUpdateHandler = { [weak self] s in if case .failed = s { self?.close(id) }; if case .cancelled = s { self?.peers.removeValue(forKey: id) } }
        c.start(queue: queue); read(id)
        queue.asyncAfter(deadline: .now()+10) { [weak self, weak p] in if let p = p, !p.ws { self?.close(id) } }
    }
    func close(_ id: UUID) { peers.removeValue(forKey: id)?.connection.cancel() }
    func read(_ id: UUID) {
        guard let p = peers[id] else { return }
        p.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self = self else { return }
            if let data = data { p.buffer.append(data) }
            if p.buffer.count > 16384 { self.close(id); return }
            if p.ws { self.messages(id) } else if p.buffer.range(of: Data("\r\n\r\n".utf8)) != nil { self.request(id) }
            if done || error != nil { self.close(id) } else if self.peers[id] != nil { self.read(id) }
        }
    }
    func reply(_ id: UUID, _ status: String, _ type: String, _ body: Data, extra: String = "") {
        guard let p = peers[id] else { return }
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\(extra)\r\n".utf8); out.append(body)
        p.connection.send(content: out, completion: .contentProcessed { [weak self] _ in self?.close(id) })
    }
    func request(_ id: UUID) {
        guard let p = peers[id], let raw = String(data: p.buffer, encoding: .utf8) else { close(id); return }
        p.buffer.removeAll()
        let lines = raw.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ")
        guard first.count == 3, first[0] == "GET", let url = URLComponents(string: String(first[1])) else { close(id); return }
        var headers: [String:String] = [:]
        for line in lines.dropFirst() { if let colon = line.firstIndex(of: ":") { headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) } }
        // Reject cross-site browser requests, including WebSocket hijacking.
        if let origin = headers["origin"], origin != "http://" + (headers["host"] ?? "") { reply(id,"403 Forbidden","text/plain",Data()); return }
        let query = url.queryItems ?? []
        let key = query.first { $0.name == "key" }?.value ?? ""
        let cookie = headers["cookie"]?.split(separator:";").contains {
            $0.trimmingCharacters(in:.whitespaces) == "ipadDisplayPair=" + token
        } ?? false
        let remember = "Set-Cookie: ipadDisplayPair=\(token); Path=/; Max-Age=31536000; HttpOnly; SameSite=Strict\r\n"
        if url.path == "/" { reply(id,"200 OK","text/html; charset=utf-8",Data(page.utf8)); return }
        if url.path == "/pair" {
            if Date().timeIntervalSince(window) > 60 { attempts = 0; window = Date() }
            attempts += 1
            guard attempts <= 5, query.first(where: { $0.name == "code" })?.value == code else { reply(id,"403 Forbidden","text/plain",Data("Неверный код или лимит попыток. Подождите минуту.".utf8)); return }
            reply(id,"200 OK","text/plain",Data(token.utf8),extra:remember); return
        }
        guard cookie || key == token else { reply(id,"403 Forbidden","text/plain",Data()); return }
        if url.path == "/session" {
            reply(id,"200 OK","text/plain",Data(),extra:remember); return
        }
        if url.path == "/cursor" {
            reply(id,"200 OK","text/plain",Data(cursorPosition().utf8)); return
        }
        if url.path == "/frame" {
            guard let frame = latest else { reply(id,"503 Unavailable","text/plain",Data()); return }
            reply(id,"200 OK","image/jpeg",frame); return
        }
        if url.path == "/ws", headers["upgrade"]?.lowercased() == "websocket", headers["sec-websocket-version"] == "13", let k = headers["sec-websocket-key"], Data(base64Encoded:k)?.count == 16 {
            p.ws = true
            let channel = query.first { $0.name == "channel" }?.value
            p.cursorOnly = channel == "cursor"
            p.separateCursor = channel == "video"
            let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(websocketAccept(k))\r\n\r\n"
            p.connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
            pump(id)
            return
        }
        reply(id,"404 Not Found","text/plain",Data())
    }
    func messages(_ id: UUID) {
        guard let p = peers[id] else { return }
        do { while let (op, data) = try consumeWS(&p.buffer) {
            if op == 8 { close(id); return }
            if op == 9 { p.connection.send(content: wsFrame(data,opcode:10),completion:.contentProcessed { _ in }); continue }
            guard op == 1, let message = String(data:data,encoding:.utf8), p.busy else { close(id); return }
            let fields = message.split(separator:":")
            guard fields.first == "ack", fields.count <= 2 else {close(id);return}
            let decodeMS = fields.count == 2 ? (Double(fields[1]) ?? 0) : 0
            let elapsed = Date().timeIntervalSince(p.sent)
            adaptive.observe(elapsed); onQuality?(quality); p.busy = false; p.ackCount += 1
            if Date().timeIntervalSince(lastStats) >= 1 {
                let period = max(0.001,Date().timeIntervalSince(p.statsEpoch))
                onStats?(String(format:"%.1f FPS ACK · цикл %.0f мс · декод. %.0f мс · JPEG %.0f%% · кодер %.1f мс · цель %.0f/60",Double(p.ackCount)/period,elapsed*1000,decodeMS,quality*100,encodeMS,targetFPS))
                p.ackCount = 0; p.statsEpoch = Date(); lastStats = Date()
            }
            pump(id)

        } } catch { close(id) }
    }
    func cursorPosition() -> String {
        guard let bounds = cursorBounds, let point = CGEvent(source:nil)?.location else {return "c:-1:-1"}
        let visible = bounds.contains(point)
        let x = visible ? Int((point.x-bounds.minX)/bounds.width*1024) : -1
        let y = visible ? Int((point.y-bounds.minY)/bounds.height*768) : -1
        return "c:\(x):\(y)"
    }
    func sendCursor() {
        let position = cursorPosition()
        for (id,p) in Array(peers) where p.ws && !p.separateCursor && !p.cursorSending && p.cursorPosition != position {
            p.cursorSending = true; p.cursorPosition = position
            p.connection.send(content:wsFrame(Data(position.utf8),opcode:1),completion:.contentProcessed { [weak self] error in
                p.cursorSending = false
                if error != nil {self?.close(id)}
            })
        }
    }
    func pump(_ id: UUID) {
        guard let p = peers[id], p.ws, !p.cursorOnly, !p.busy, latestVersion > p.lastVersion, let frame = latest else {return}
        let delay = 1/targetFPS - Date().timeIntervalSince(p.sent)
        if delay > 0 {
            guard !p.pumpScheduled else {return}
            p.pumpScheduled = true
            queue.asyncAfter(deadline:.now()+delay) { [weak self] in p.pumpScheduled = false; self?.pump(id) }
            return
        }
        p.busy = true; p.sent = Date(); p.lastVersion = latestVersion
        p.connection.send(content:wsFrame(frame),completion:.contentProcessed { [weak self] error in if error != nil {self?.close(id)} })
    }
    func publish(_ frame: Data, encodeMilliseconds: Double = 0) {
        queue.async { [self] in
            defer { self.frameGate.signal() }
            latest = frame; latestAt = Date(); latestVersion += 1
            encodeMS = encodeMS * 0.8 + encodeMilliseconds * 0.2
            for (id,p) in Array(peers) where p.ws {
                if p.busy { if Date().timeIntervalSince(p.sent) > 4 {close(id)}; continue }
                pump(id)
            }
        }
    }
}
