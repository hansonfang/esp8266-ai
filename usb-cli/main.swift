import Foundation
import Network
import Darwin

private let defaultPort: UInt16 = 8765

final class USBClock {
    private let service: StatusService
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var port = ""
    private var linked = false
    private var lastTry = Date.distantPast
    private var lastHello = Date.distantPast
    private var lastStatus = Date.distantPast
    private var lastInfo = Date.distantPast
    private var input = Data()
    private var timer: Timer?
    private var nextID = 1
    private var acknowledgements: [Int: [String: Any]] = [:]
    private var brightness: Int?
    private var display: String?

    init(service: StatusService) { self.service = service }

    var state: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["connected": linked, "port": port, "brightness": brightness.map { $0 as Any } ?? NSNull(), "display": display ?? NSNull()]
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    func setBrightness(_ level: Int) -> [String: Any]? {
        guard (0...100).contains(level) else { return nil }
        return command(["brightness": level])
    }

    func setDisplay(_ mode: String) -> [String: Any]? {
        guard ["auto", "claude", "codex", "net", "music", "stock"].contains(mode) else { return nil }
        return command(["display": mode])
    }

    private func command(_ body: [String: Any]) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard linked else { return nil }
        let id = nextID; nextID += 1
        var payload = body; payload["id"] = id
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var frame = Data("#CMD ".utf8); frame.append(json); frame.append(0x0A)
        guard writeLocked(frame) else { return nil }
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            readPending()
            if let ack = acknowledgements.removeValue(forKey: id) { return ack }
            usleep(10_000)
        }
        return nil
    }

    private func tick() {
        lock.lock(); defer { lock.unlock() }
        if fd < 0 {
            if Date().timeIntervalSince(lastTry) > 2 { lastTry = Date(); openFirstPort() }
            return
        }
        readPending()
        let now = Date()
        if !linked {
            if now.timeIntervalSince(lastHello) > 2 {
                lastHello = now
                _ = writeLocked(Data("#HELLO\n".utf8))
            }
            return
        }
        if now.timeIntervalSince(lastStatus) > 5 {
            lastStatus = now
            var frame = Data("#STATUS ".utf8)
            frame.append(service.snapshot().jsonData())
            frame.append(0x0A)
            _ = writeLocked(frame)
        }
        if now.timeIntervalSince(lastInfo) > 30 {
            lastInfo = now
            let id = nextID; nextID += 1
            _ = writeLocked(Data("#INFO? {\"id\":\(id)}\n".utf8))
        }
    }

    private func openFirstPort() {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []).filter {
            $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.wchusbserial")
        }.sorted()
        for name in names where openPort("/dev/" + name) { return }
    }

    private func openPort(_ path: String) -> Bool {
        let candidate = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard candidate >= 0 else { return false }
        var tio = termios()
        guard tcgetattr(candidate, &tio) == 0 else { Darwin.close(candidate); return false }
        cfmakeraw(&tio)
        cfsetspeed(&tio, speed_t(B115200))
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tio.c_cflag &= ~tcflag_t(HUPCL)
        guard tcsetattr(candidate, TCSANOW, &tio) == 0 else { Darwin.close(candidate); return false }
        fd = candidate; port = path; linked = false; input.removeAll()
        FileHandle.standardError.write(Data("[usb] trying \(path)\n".utf8))
        return true
    }

    private func closePort() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1; port = ""; linked = false; input.removeAll()
    }

    private func send(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return writeLocked(data)
    }

    private func writeLocked(_ data: Data) -> Bool {
        guard fd >= 0 else { return false }
        var offset = 0
        while offset < data.count {
            let wrote = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if wrote > 0 { offset += wrote; continue }
            if wrote < 0 && errno == EINTR { continue }
            if wrote < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return false }
            closePort(); return false
        }
        return true
    }

    private func readPending() {
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 { input.append(contentsOf: buffer[0..<count]); continue }
            if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK) { closePort() }
            break
        }
        while let newline = input.firstIndex(of: 0x0A) {
            let line = String(decoding: input[..<newline], as: UTF8.self)
            input.removeSubrange(...newline)
            if line.hasPrefix("#DEVICE") {
                linked = true; lastStatus = .distantPast; lastInfo = .distantPast
                FileHandle.standardError.write(Data("[usb] connected \(port)\n".utf8))
            }
            if line.hasPrefix("#ACK "), let data = line.dropFirst(5).data(using: .utf8),
               let ack = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = ack["id"] as? Int {
                acknowledgements[id] = ack
                brightness = (ack["brightness"] as? NSNumber)?.intValue ?? brightness
                display = ack["display"] as? String ?? display
            }
            if line.hasPrefix("#INFO "), let data = line.dropFirst(6).data(using: .utf8),
               let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                brightness = (info["brightness"] as? NSNumber)?.intValue ?? brightness
                display = info["display"] as? String ?? display
            }
        }
        if input.count > 16_384 { input.removeAll() }
    }
}

final class LocalServer {
    private let service: StatusService
    private let clock: USBClock
    private let listener: NWListener
    private let queue = DispatchQueue(label: "aiclock-usb.http")

    init(port: UInt16, service: StatusService, clock: USBClock) throws {
        self.service = service; self.clock = clock
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
    }

    func start() { listener.start(queue: queue) }

    private func accept(_ connection: NWConnection) {
        if case let .hostPort(host, _) = connection.endpoint,
           host != .ipv4(.loopback), host != .ipv6(.loopback) {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self, let data else { connection.cancel(); return }
            self.reply(connection, request: data)
        }
    }

    private func reply(_ connection: NWConnection, request: Data) {
        let text = String(decoding: request, as: UTF8.self)
        let lines = text.split(whereSeparator: { $0.isNewline })
        let parts = (lines.first ?? "").split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let path = parts.dropFirst().first.map { String($0.split(separator: "?").first ?? "") } ?? "/"
        let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        var code = "200 OK", type = "application/json; charset=utf-8", payload = Data()
        if method == "GET" && path == "/" {
            type = "text/html; charset=utf-8"; payload = Data(Self.page.utf8)
        } else if method == "GET" && path == "/api/status" {
            payload = statusData()
        } else if method == "POST" && path == "/api/brightness" {
            let value = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            let level = (value?["level"] as? NSNumber)?.intValue ?? -1
            if let ack = clock.setBrightness(level), (ack["ok"] as? Bool) == true { payload = json(ack) }
            else { code = "409 Conflict"; payload = json(["error": "Clock did not confirm the brightness command"]) }
        } else if method == "POST" && path == "/api/display" {
            let value = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            if let mode = value?["mode"] as? String, let ack = clock.setDisplay(mode), (ack["ok"] as? Bool) == true { payload = json(ack) }
            else { code = "409 Conflict"; payload = json(["error": "Clock did not confirm the display command"]) }
        } else if method == "POST" && path == "/event" {
            if let event = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
               let name = event["event"] as? String {
                service.recordEvent(agent: event["agent"] as? String ?? "codex", event: name, message: event["message"] as? String)
            }
            payload = json(["ok": true])
        } else { code = "404 Not Found"; type = "text/plain; charset=utf-8"; payload = Data("not found".utf8) }
        let header = "HTTP/1.1 \(code)\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8); response.append(payload)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func statusData() -> Data {
        let s = service.snapshot().codex
        return json([
            "usb": clock.state,
            "codex": ["status": s.status, "weekly_pct": s.weeklyPct.map { $0 as Any } ?? NSNull(), "weekly_reset_min": s.weeklyResetMin.map { $0 as Any } ?? NSNull(),
                      "primary_pct": s.primaryPct.map { $0 as Any } ?? NSNull(), "primary_reset_min": s.primaryResetMin.map { $0 as Any } ?? NSNull()]
        ])
    }

    private func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8) }

    private static let page = """
    <!doctype html><meta name=viewport content="width=device-width,initial-scale=1"><title>AI Clock USB</title>
    <style>body{margin:0;background:#101114;color:#e8eaed;font:15px -apple-system,BlinkMacSystemFont,sans-serif}main{max-width:560px;margin:10vh auto;padding:28px;border:1px solid #2c3038;border-radius:14px;background:#181a1f}h1{font-size:20px;margin:0 0 22px}.row{display:flex;justify-content:space-between;padding:13px 0;border-top:1px solid #2c3038}.muted{color:#9aa0a6}strong{font-variant-numeric:tabular-nums}input{width:100%;accent-color:#8ab4f8}button{margin-top:16px;padding:9px 13px;border:0;border-radius:7px;background:#8ab4f8;color:#101114;font-weight:600}#notice{margin-top:12px;color:#9aa0a6}</style>
    <main><h1>AI Clock · USB</h1><div class=row><span>USB</span><strong id=usb>连接中</strong></div><div class=row><span>Codex</span><strong id=status>—</strong></div><div class=row><span>周额度</span><strong id=weekly>—</strong></div><div class=row><span>重置</span><strong id=reset>—</strong></div><div class=row><span>显示</span><select id=mode onchange=setMode()><option value=auto>自动</option><option value=codex>Codex</option><option value=claude>Claude</option><option value=net>网速</option><option value=music>音乐</option><option value=stock>股票</option></select></div><div class=row><span>亮度 <strong id=level>100%</strong></span></div><input id=brightness type=range min=0 max=100 value=100><button onclick=save()>应用亮度</button><div id=notice>网页关闭后，后台服务仍持续更新时钟。</div></main>
    <script>const f=n=>n==null?'—':n+'%';const m=n=>n==null?'—':n<60?n+' 分钟':Math.floor(n/60)+' 小时';async function load(){try{let x=await fetch('/api/status').then(r=>r.json()),c=x.codex,u=x.usb;usb.textContent=u.connected?'已连接 '+u.port:'未连接';status.textContent=c.status;weekly.textContent=f(c.weekly_pct);reset.textContent=m(c.weekly_reset_min);if(u.brightness!=null){brightness.value=u.brightness;levelEl.textContent=u.brightness+'%'}if(u.display)mode.value=u.display}catch{usb.textContent='服务不可用'}}async function call(path,body){let r=await fetch(path,{method:'POST',body:JSON.stringify(body)});let x=await r.json();notice.textContent=r.ok?'设备已确认：'+(x.brightness??'')+'%':x.error}async function save(){await call('/api/brightness',{level:+brightness.value})}async function setMode(){await call('/api/display',{mode:mode.value})}const levelEl=document.querySelector('#level');brightness.oninput=()=>levelEl.textContent=brightness.value+'%';load();setInterval(load,3000)</script>
    """
}

private func printUsage() {
    print("Usage: aiclock-usb <serve|status|brightness|doctor|open|install|uninstall>")
}

private func installLaunchAgent() throws {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let binDir = home.appendingPathComponent("Library/Application Support/AIClockUSB")
    let bin = binDir.appendingPathComponent("aiclock-usb")
    try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
    if fm.fileExists(atPath: bin.path) { try fm.removeItem(at: bin) }
    try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: bin)
    let plist = home.appendingPathComponent("Library/LaunchAgents/local.aiclock-usb.plist")
    let text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict><key>Label</key><string>local.aiclock-usb</string><key>ProgramArguments</key><array><string>\(bin.path)</string><string>serve</string></array><key>RunAtLoad</key><true/><key>KeepAlive</key><true/></dict></plist>"
    try text.data(using: .utf8)!.write(to: plist)
    let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/launchctl"); task.arguments = ["bootstrap", "gui/\(getuid())", plist.path]
    try task.run(); task.waitUntilExit()
    guard task.terminationStatus == 0 else { throw NSError(domain: "aiclock-usb", code: 1, userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed"]) }
    print("Installed. The USB bridge now starts automatically after login.")
}

private func uninstallLaunchAgent() {
    let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.aiclock-usb.plist")
    let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/launchctl"); task.arguments = ["bootout", "gui/\(getuid())/local.aiclock-usb"]
    try? task.run(); task.waitUntilExit(); try? FileManager.default.removeItem(at: path)
    print("Uninstalled.")
}

let command = CommandLine.arguments.dropFirst().first ?? "serve"
let service = StatusService()
let usage = UsageFetcher(); service.usage = usage

switch command {
case "serve":
    usage.startAutoRefresh()
    let clock = USBClock(service: service); clock.start()
    do { let server = try LocalServer(port: defaultPort, service: service, clock: clock); server.start(); print("AI Clock USB is running at http://127.0.0.1:\(defaultPort)"); RunLoop.main.run() }
    catch { fputs("Could not start server: \(error.localizedDescription)\n", stderr); exit(1) }
case "status":
    let s = service.snapshot().codex
    let data = try! JSONSerialization.data(withJSONObject: ["status": s.status, "weekly_pct": s.weeklyPct.map { $0 as Any } ?? NSNull(), "weekly_reset_min": s.weeklyResetMin.map { $0 as Any } ?? NSNull()])
    print(String(decoding: data, as: UTF8.self))
case "brightness":
    guard let raw = CommandLine.arguments.dropFirst(2).first, let level = Int(raw), (0...100).contains(level) else { printUsage(); exit(2) }
    let clock = USBClock(service: service); clock.start()
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    guard let ack = clock.setBrightness(level), (ack["ok"] as? Bool) == true else { fputs("Clock did not confirm the brightness command.\n", stderr); exit(1) }
    print("Brightness confirmed: \(ack["brightness"] ?? level)%")
case "doctor":
    let ports = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []).filter { $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.wchusbserial") }
    print("USB ports: \(ports.isEmpty ? "none" : ports.map { "/dev/" + $0 }.joined(separator: ", "))")
    let auth = ("~/.codex/auth.json" as NSString).expandingTildeInPath
    print("Codex credentials: \(FileManager.default.fileExists(atPath: auth) ? "found" : "not found")")
case "open":
    let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/open"); task.arguments = ["http://127.0.0.1:\(defaultPort)"]; try? task.run()
case "install":
    do { try installLaunchAgent() } catch { fputs("Install failed: \(error.localizedDescription)\n", stderr); exit(1) }
case "uninstall": uninstallLaunchAgent()
default: printUsage(); exit(2)
}
