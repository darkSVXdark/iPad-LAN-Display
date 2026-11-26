import Foundation
import Darwin
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@main struct Runner {
    static func main() throws {
        func check(_ condition: @autoclosure () -> Bool, _ label: String) { if !condition() { fatalError(label) }; print("PASS: \(label)") }
        var gate = CaptureAccessGate()
        var preflightChecks = 0, enumerations = 0
        // Simulate 100 discovery ticks after a denial: no capture API may run.
        for _ in 0..<100 {
            if gate.permitsEnumeration(preflight: { preflightChecks += 1; return false }) {enumerations += 1}
        }
        check(enumerations == 0, "denied permission: no enumeration over 100 timer ticks")
        gate.failed()
        preflightChecks = 0
        for _ in 0..<100 {
            if gate.permitsEnumeration(preflight: {preflightChecks += 1; return true}) {enumerations += 1}
        }
        check(enumerations == 0 && preflightChecks == 0, "capture failure pauses timer even when preflight says granted")
        gate.userRetry()
        check(gate.permitsEnumeration(preflight: {true}), "explicit retry enables capture with permission")
        check(!gate.permitsEnumeration(preflight: {false}), "explicit retry cannot bypass macOS permission")
        check(websocketAccept("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=","RFC6455 handshake")
        var a = Adaptive(); for _ in 0..<1000 {a.observe(0.5)}
        check(a.fps == 5 && a.quality == 0.70,"slow client lower bounds")
        for _ in 0..<1000 {a.observe(0.02)}
        check(a.fps > 47 && a.fps < 48 && a.quality == 0.90,"fast client upper bounds")
        for _ in 0..<100 {a.observe(0.064)}
        check(a.fps > 14 && a.fps < 16, "64ms client recovers to throughput limit instead of sticking at 5 FPS")
        for _ in 0..<100 {a.observe(0.01)}
        check(a.fps == 60, "fast client reaches target ceiling 60 FPS")
        let unchanged = a.fps; a.observe(.nan); a.observe(-1)
        check(a.fps == unchanged, "invalid timing samples ignored")
        check(Array(wsFrame(Data(repeating:1,count:126)).prefix(4)) == [130,126,0,126],"16 bit frame length")
        check(Array(wsFrame(Data(repeating:1,count:65536)).prefix(10)) == [130,127,0,0,0,0,0,1,0,0],"64 bit frame length")
        var data = Data([129,131,1,2,3,4,96,97]); let partial = try consumeWS(&data); check(partial == nil,"partial frame retained"); data.append(104)
        let ack = try consumeWS(&data); check(ack?.1 == Data("ack".utf8) && data.isEmpty,"masked ACK decode")
        var bad = Data([129,3,97,99,107]); var rejected = false
        do { _ = try consumeWS(&bad) } catch {rejected = true}; check(rejected,"unmasked frame rejected")
        setbuf(stdout,nil)
        let server = Server(persist:false); server.code = "12345678"; server.token = "test-token"; server.page = "test-page"
        server.setMaximum(true)
        check(server.queue.sync { server.quality == 0.95 && server.targetFPS == 60 }, "maximum mode uses JPEG 95 and 60 FPS cap")
        server.setMaximum(false)
        check(server.queue.sync { server.quality == 0.82 }, "adaptive mode restores adaptive quality")
        server.onStats = { print($0) }
        try server.start(ip:"127.0.0.1",port:18766)
        func get(_ path: String, origin: String? = nil, cookie: String? = nil) -> (Int,Data) {
            let sem = DispatchSemaphore(value:0)
            var request = URLRequest(url:URL(string:"http://127.0.0.1:18766"+path)!)
            request.timeoutInterval = 3
            if let origin = origin {request.setValue(origin,forHTTPHeaderField:"Origin")}
            if let cookie = cookie {request.setValue(cookie,forHTTPHeaderField:"Cookie")}
            var result = (0,Data())
            URLSession(configuration:.ephemeral).dataTask(with:request) {data,response,error in result = ((response as? HTTPURLResponse)?.statusCode ?? 0,data ?? Data()); sem.signal()}.resume()
            _ = sem.wait(timeout:.now()+5); return result
        }
        let home = get("/"); print("HTTP status",home.0)
        check(home.0 == 200,"HTTP page")
        check(get("/cursor").0 == 403,"cursor requires token")
        check(get("/cursor?key=test-token").1 == Data("c:-1:-1".utf8),"hidden cursor without active capture")
        check(get("/session").0 == 403,"anonymous session rejected")
        check(get("/session?key=test-token").0 == 200,"legacy pairing can be restored")
        check(get("/session",cookie:"ipadDisplayPair=test-token").0 == 200,"saved cookie restores pair without code")
        check(get("/session",cookie:"ipadDisplayPair=revoked").0 == 403,"revoked cookie rejected")
        check(get("/frame").0 == 403,"frame requires token")
        check(get("/pair?code=00000000").0 == 403,"wrong pairing code")
        check(get("/pair?code=12345678").1 == Data("test-token".utf8),"correct pairing code")
        check(get("/pair?code=12345678",origin:"http://evil.example").0 == 403,"cross origin pairing rejected")
        check(get("/frame?key=test-token").0 == 503,"no stale frame without capture")
        let image = CIImage(color:CIColor(red:1,green:0,blue:0)).cropped(to:CGRect(x:0,y:0,width:1024,height:768))
        let cg = CIContext().createCGImage(image,from:image.extent)!
        let jpeg = NSMutableData()
        let dst = CGImageDestinationCreateWithData(jpeg,UTType.jpeg.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(dst,cg,nil); check(CGImageDestinationFinalize(dst),"synthetic JPEG encode")
        server.frameGate.wait(); server.publish(jpeg as Data)
        let response = get("/frame?key=test-token")
        let source = CGImageSourceCreateWithData(response.1 as CFData,nil)!
        let decoded = CGImageSourceCreateImageAtIndex(source,0,nil)!
        check(response.0 == 200 && decoded.width == 1024 && decoded.height == 768,"HTTP JPEG decodes at 1024x768")
        server.queue.sync {server.latest = nil}
        let socket = URLSession(configuration:.ephemeral).webSocketTask(with:URL(string:"ws://127.0.0.1:18766/ws?key=test-token")!)
        socket.resume()
        let received = DispatchSemaphore(value:0)
        Task.detached {
            do {
                var message = try await socket.receive()
                while case .string = message {message = try await socket.receive()}
                if case .data(let frame) = message { precondition(frame == jpeg as Data,"WebSocket binary JPEG"); print("PASS: WebSocket binary JPEG") } else {fatalError("Expected JPEG")}
                received.signal()
            } catch { print(error); received.signal() }
        }
        server.queue.asyncAfter(deadline:.now()+0.3) {server.frameGate.wait(); server.publish(jpeg as Data)}
        check(received.wait(timeout:.now()+4) == .success,"WebSocket receive timeout")
        let busy = server.queue.sync {server.peers.values.contains {$0.ws && $0.busy}}
        check(busy,"frame held until decode ACK")
        let sentAck = DispatchSemaphore(value:0)
        Task.detached { try? await socket.send(.string("ack:12")); sentAck.signal() }
        _ = sentAck.wait(timeout:.now()+2)
        let ackObserved = DispatchSemaphore(value:0)
        server.queue.asyncAfter(deadline:.now()+0.2) { if server.peers.values.contains(where:{$0.ws && !$0.busy}) { ackObserved.signal() } }
        check(ackObserved.wait(timeout:.now()+2) == .success,"decode ACK releases frame slot")
        let producer = DispatchSource.makeTimerSource(queue:server.queue)
        producer.schedule(deadline:.now(),repeating:.milliseconds(8))
        producer.setEventHandler {
            if server.frameGate.wait(timeout:.now()) == .success {server.publish(jpeg as Data)}
        }
        producer.resume()
        let bench = DispatchSemaphore(value:0)
        Task.detached {
            do {
                let started = ProcessInfo.processInfo.systemUptime
                for _ in 0..<60 {
                    var frame = try await socket.receive()
                    while case .string = frame {frame = try await socket.receive()}
                    try await socket.send(.string("ack:1"))
                }
                let fps = 60/(ProcessInfo.processInfo.systemUptime-started)
                precondition(fps > 40 && fps < 75,"Local 60 FPS ceiling regression")
                print(String(format:"PASS: local synthetic WebSocket %.1f FPS (not iPad)",fps))
                bench.signal()
            } catch { print("Benchmark error",error) }
        }
        check(bench.wait(timeout:.now()+4) == .success,"local synthetic 60-frame ACK run")
        producer.cancel()
        socket.cancel(with:.goingAway,reason:nil)
        for _ in 0..<4 {_ = get("/pair?code=00000000")}
        check(get("/pair?code=12345678").0 == 403,"pairing rate limit")
        server.stop()
        print("All checks passed")
    }
}
