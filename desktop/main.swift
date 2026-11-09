// chanelu 데스크톱 펫: 투명 창으로 화면 아래(Dock 위)를 돌아다녀요.
// 사용법: chanelu-desktop <sheet.png> <socket-path> [size speed sleepAfterSeconds]
// VS Code 확장이 유닉스 소켓으로 한 줄짜리 명령을 보내요: typing | saved | pet | sleep | config <size> <speed> <sleep> | quit
// 연결된 VS Code 창이 하나도 없으면 몇 초 뒤 스스로 종료해요.
import AppKit

signal(SIGPIPE, SIG_IGN)

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: chanelu-desktop <sheet.png> <socket> [size speed sleepAfter]\n".data(using: .utf8)!)
    exit(2)
}
let sheetPath = args[1]
let sockPath = args[2]
var cfgSize: CGFloat = args.count > 3 ? CGFloat(Double(args[3]) ?? 96) : 96
var cfgSpeed: CGFloat = args.count > 4 ? CGFloat(Double(args[4]) ?? 60) : 60
var cfgSleep: Double = args.count > 5 ? (Double(args[5]) ?? 120) : 120

// ---- 한 번에 하나만 실행 (VS Code 창이 여러 개여도 chanelu는 한 마리) ----
let lockFd = open(sockPath + ".lock", O_CREAT | O_RDWR, 0o600)
if lockFd < 0 || flock(lockFd, LOCK_EX | LOCK_NB) != 0 { exit(0) }

func quit() -> Never {
    unlink(sockPath)
    exit(0)
}

// ---- 스프라이트 ----
let FW = 110, FH = 145, COLS = 8, ROWS = 11
enum Row: Int {
    case idle = 0, look, happy, wave, hop, walkRight, walkLeft, beg, sit, sitBlink, sleep
}

func loadFrames() -> [[CGImage]] {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: sheetPath) as CFURL, nil),
          let sheet = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        FileHandle.standardError.write("cannot load sheet\n".data(using: .utf8)!)
        exit(3)
    }
    return (0..<ROWS).map { r in
        (0..<COLS).map { c in sheet.cropping(to: CGRect(x: c * FW, y: r * FH, width: FW, height: FH))! }
    }
}

// ---- 창 ----
final class PupWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PupView: NSView {
    weak var ctl: Controller?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { ctl?.mouseDown() }
    override func mouseDragged(with e: NSEvent) { ctl?.mouseDragged() }
    override func mouseUp(with e: NSEvent) { ctl?.mouseUp() }
}

final class Controller {
    enum Mode { case idle, walk, busy, sleeping, dragging, falling }
    struct Anim {
        var row: Row
        var frames: [Int]
        var dur: Double
        var loop: Bool
        var onDone: (() -> Void)?
    }

    let frames: [[CGImage]]
    let window: PupWindow
    let view: PupView
    let dog = CALayer()
    let headroom: CGFloat = 44

    var w: CGFloat = 0, h: CGFloat = 0
    var x: CGFloat = 0, y: CGFloat = 0, vy: CGFloat = 0
    var mode = Mode.idle
    var anim: Anim?
    var fi = 0, ft = 0.0
    var target: CGFloat = 0, dir: CGFloat = 1
    var restUntil = 0.0
    var lastInput = CACurrentMediaTime()
    var zzz = 0.0
    var prev = CACurrentMediaTime()
    var dragOffset = CGPoint.zero
    var dragMoved = false

    init(frames: [[CGImage]]) {
        self.frames = frames
        window = PupWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        view = PupView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear
        dog.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        dog.minificationFilter = .trilinear
        dog.contentsGravity = .resizeAspect
        view.layer?.addSublayer(dog)
        window.contentView = view
        view.ctl = self

        applySize()
        let sf = screen().visibleFrame
        x = sf.minX + CGFloat.random(in: 0...max(1, sf.width - w))
        y = sf.minY
        window.setFrameOrigin(NSPoint(x: x, y: y))
        window.orderFrontRegardless()
        startIdle()
    }

    func screen() -> NSScreen { screenAt(x + w / 2, y) }

    /// 강아지 발 위치(cx, footY)가 속한 화면. 가로로 겹치는 화면이 여럿이면(위아래 배치) 발 높이에 가까운 쪽.
    func screenAt(_ cx: CGFloat, _ footY: CGFloat) -> NSScreen {
        let all = NSScreen.screens
        guard !all.isEmpty else { return NSScreen.main! }
        let hits = all.filter { $0.frame.minX <= cx && cx < $0.frame.maxX }
        // 발 아래에 있는 바닥 중 가장 높은 것 (위 모니터에서 떨어뜨리면 위 모니터 바닥에 착지)
        if let s = hits.filter({ $0.visibleFrame.minY <= footY + 1 }).max(by: { $0.visibleFrame.minY < $1.visibleFrame.minY }) { return s }
        if let s = hits.min(by: { abs($0.visibleFrame.minY - footY) < abs($1.visibleFrame.minY - footY) }) { return s }
        // 화면 사이 빈틈이면 가장 가까운 화면
        return all.min(by: { dist($0, cx) < dist($1, cx) })!
    }

    func dist(_ s: NSScreen, _ cx: CGFloat) -> CGFloat {
        cx < s.frame.minX ? s.frame.minX - cx : (cx >= s.frame.maxX ? cx - s.frame.maxX : 0)
    }

    func applySize() {
        h = cfgSize
        w = CGFloat(FW) * cfgSize / CGFloat(FH)
        window.setContentSize(NSSize(width: w, height: h + headroom))
        dog.frame = CGRect(x: 0, y: 0, width: w, height: h)
    }

    // ---- 애니메이션 ----
    func setFrame(_ row: Row, _ col: Int) { dog.contents = frames[row.rawValue][col] }

    func play(_ row: Row, frames f: [Int] = Array(0...7), dur: Double = 0.14, loop: Bool = false, onDone: (() -> Void)? = nil) {
        anim = Anim(row: row, frames: f, dur: dur, loop: loop, onDone: onDone)
        fi = 0; ft = 0
        setFrame(row, f[0])
    }

    func advance(_ dt: Double) {
        guard var a = anim else { return }
        ft += dt
        while ft >= a.dur {
            ft -= a.dur
            fi += 1
            if fi >= a.frames.count {
                if a.loop { fi = 0 } else {
                    fi = a.frames.count - 1
                    let done = a.onDone
                    a.onDone = nil
                    a.dur = .infinity
                    anim = a
                    setFrame(a.row, a.frames[fi])
                    done?()
                    return
                }
            }
            setFrame(a.row, a.frames[fi])
        }
    }

    // ---- 상태 ----
    func startIdle() {
        mode = .idle
        let row = [Row.idle, .idle, .look, .happy, .sit, .sitBlink].randomElement()!
        restUntil = CACurrentMediaTime() + 2 + Double.random(in: 0...5)
        play(row, dur: 0.16, loop: true)
    }

    func startWalk() {
        mode = .walk
        // 모니터가 여러 대면 가끔(25%) 옆 모니터로 놀러 가요. 가로로 이어진 화면이어야 걸어서 갈 수 있어요.
        var sf = screen().visibleFrame
        let here = screen()
        let neighbors = NSScreen.screens.filter { s in
            s != here && (abs(s.frame.minX - here.frame.maxX) < 2 || abs(s.frame.maxX - here.frame.minX) < 2)
        }
        if let next = neighbors.randomElement(), Double.random(in: 0...1) < 0.25 {
            sf = next.visibleFrame
            target = CGFloat.random(in: sf.minX...max(sf.minX + 1, sf.maxX - w))
            dir = target > x ? 1 : -1
            play(dir > 0 ? .walkRight : .walkLeft, dur: 0.1, loop: true)
            return
        }
        let maxX = sf.maxX - w
        target = CGFloat.random(in: sf.minX...max(sf.minX + 1, maxX))
        // 너무 가까우면 좀 더 멀리
        if abs(target - x) < 60 { target = x < (sf.minX + maxX) / 2 ? min(maxX, x + 300) : max(sf.minX, x - 300) }
        dir = target > x ? 1 : -1
        play(dir > 0 ? .walkRight : .walkLeft, dur: 0.1, loop: true)
    }

    func trick(_ row: Row) {
        mode = .busy
        play(row, dur: 0.11, onDone: { [unowned self] in self.startIdle() })
    }

    func fallAsleep() {
        if mode == .sleeping || mode == .dragging || mode == .falling { return }
        mode = .busy
        play(.sleep, frames: Array(0...4), dur: 0.22, onDone: { [unowned self] in
            self.mode = .sleeping
            self.play(.sleep, frames: Array(4...7), dur: 0.45, loop: true)
        })
    }

    func wakeUp(_ then: @escaping () -> Void) {
        if mode != .sleeping { then(); return }
        mode = .busy
        play(.sleep, frames: [3, 2, 1, 0], dur: 0.15, onDone: then)
    }

    func pet() {
        lastInput = CACurrentMediaTime()
        popup("❤️", color: nil)
        wakeUp { [unowned self] in self.trick([.hop, .wave, .beg, .happy].randomElement()!) }
    }

    // ---- 효과 ----
    func popup(_ text: String, color: NSColor?) {
        guard let root = view.layer else { return }
        let t = CATextLayer()
        t.string = text
        t.fontSize = 15
        t.alignmentMode = .center
        t.contentsScale = screen().backingScaleFactor
        if let c = color { t.foregroundColor = c.cgColor }
        t.frame = CGRect(x: w / 2 - 12 + CGFloat.random(in: -8...8), y: h - 10, width: 24, height: 22)
        root.addSublayer(t)
        let rise = CABasicAnimation(keyPath: "position.y")
        rise.byValue = 34
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [rise, fade]
        g.duration = color == nil ? 1.2 : 2.2
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        g.isRemovedOnCompletion = false
        g.fillMode = .forwards
        t.add(g, forKey: "float")
        DispatchQueue.main.asyncAfter(deadline: .now() + g.duration) { t.removeFromSuperlayer() }
    }

    // ---- 마우스: 클릭하면 반응, 드래그하면 들어 올리기 ----
    func mouseDown() {
        let m = NSEvent.mouseLocation
        dragOffset = CGPoint(x: m.x - window.frame.minX, y: m.y - window.frame.minY)
        dragMoved = false
    }

    func mouseDragged() {
        if !dragMoved {
            dragMoved = true
            lastInput = CACurrentMediaTime()
            mode = .dragging
            play(.beg, frames: [2, 3, 4, 3], dur: 0.12, loop: true)
        }
        let m = NSEvent.mouseLocation
        x = m.x - dragOffset.x
        y = m.y - dragOffset.y
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func mouseUp() {
        if dragMoved { mode = .falling; vy = 0 } else { pet() }
    }

    // ---- VS Code에서 온 명령 ----
    func handle(_ line: String) {
        let p = line.split(separator: " ").map(String.init)
        guard let cmd = p.first else { return }
        let held = mode == .dragging || mode == .falling
        switch cmd {
        case "typing":
            lastInput = CACurrentMediaTime()
            if mode == .sleeping { wakeUp { [unowned self] in self.startIdle() } }
        case "saved":
            lastInput = CACurrentMediaTime()
            if !held { wakeUp { [unowned self] in self.trick(.hop) } }
        case "pet":
            if !held { pet() }
        case "sleep":
            fallAsleep()
        case "config" where p.count >= 4:
            cfgSize = CGFloat(Double(p[1]) ?? Double(cfgSize))
            cfgSpeed = CGFloat(Double(p[2]) ?? Double(cfgSpeed))
            cfgSleep = Double(p[3]) ?? cfgSleep
            applySize()
        case "quit":
            quit()
        default:
            break
        }
    }

    // ---- 매 프레임 ----
    func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.1, now - prev)
        prev = now
        advance(dt)

        switch mode {
        case .walk:
            x += dir * cfgSpeed * CGFloat(dt)
            if (dir > 0 && x >= target) || (dir < 0 && x <= target) { x = target; startIdle() }
        default:
            break
        }
        // 걸어서 옆 모니터로 넘어가면 그 모니터 바닥을 따라가요
        let sf = screen().visibleFrame
        switch mode {
        case .idle:
            if now > restUntil { Double.random(in: 0...1) < 0.7 ? startWalk() : startIdle() }
        case .sleeping:
            zzz += dt
            if zzz > 1.6 { zzz = 0; popup("z", color: .secondaryLabelColor) }
        case .falling:
            vy -= 2400 * CGFloat(dt)
            y += vy * CGFloat(dt)
            if y <= sf.minY { y = sf.minY; vy = 0; trick(.hop) }
        default:
            break
        }

        if cfgSleep > 0 && (mode == .idle || mode == .walk) && now - lastInput > cfgSleep { fallAsleep() }

        if mode != .dragging {
            if mode != .falling { y = sf.minY }
            if mode == .walk {
                // 걷는 중에는 모든 화면을 합친 범위 안에서만 막아요 (모니터 사이를 지나갈 수 있게)
                let all = NSScreen.screens.map { $0.visibleFrame }
                x = max(all.map { $0.minX }.min() ?? sf.minX, min(x, (all.map { $0.maxX }.max() ?? sf.maxX) - w))
            } else {
                x = max(sf.minX, min(x, sf.maxX - w))
            }
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // 강아지 위에 마우스가 있을 때만 클릭을 받고, 나머지는 아래 창으로 통과
        let m = NSEvent.mouseLocation
        let dogRect = NSRect(x: window.frame.minX, y: window.frame.minY, width: w, height: h)
        window.ignoresMouseEvents = !(mode == .dragging || dogRect.contains(m))
    }
}

// ---- 소켓 서버 ----
final class Client {
    let fd: Int32
    var src: DispatchSourceRead?
    var buf: [UInt8] = []
    init(fd: Int32) { self.fd = fd }
}

final class Server {
    let onLine: (String) -> Void
    var listenSrc: DispatchSourceRead?
    var clients: [Int32: Client] = [:]
    var emptySince: Double? = CACurrentMediaTime()

    init(path: String, onLine: @escaping (String) -> Void) {
        self.onLine = onLine
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8.prefix(100))
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard fd >= 0, ok == 0, listen(fd, 16) == 0 else {
            FileHandle.standardError.write("cannot listen on \(path)\n".data(using: .utf8)!)
            exit(4)
        }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [unowned self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { break }
                self.add(c)
            }
        }
        src.resume()
        listenSrc = src
    }

    func add(_ fd: Int32) {
        let client = Client(fd: fd)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [unowned self] in
            var tmp = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { self.remove(fd); return }
            client.buf.append(contentsOf: tmp[0..<n])
            while let i = client.buf.firstIndex(of: 10) {
                let line = String(decoding: client.buf[0..<i], as: UTF8.self)
                client.buf.removeSubrange(0...i)
                self.onLine(line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        src.setCancelHandler { close(fd) }
        client.src = src
        clients[fd] = client
        emptySince = nil
        src.resume()
    }

    func remove(_ fd: Int32) {
        clients[fd]?.src?.cancel()
        clients[fd] = nil
        if clients.isEmpty { emptySince = CACurrentMediaTime() }
    }
}

// ---- 시작 ----
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // Dock 아이콘 없이
let ctl = Controller(frames: loadFrames())
let server = Server(path: sockPath) { ctl.handle($0) }

let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
    ctl.tick()
    if let t = server.emptySince, CACurrentMediaTime() - t > 5 { quit() }
}
RunLoop.main.add(timer, forMode: .common)
app.run()
