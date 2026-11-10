// chanelu 데스크톱 펫: 투명 창으로 화면 아래(Dock 위)를 돌아다녀요.
//
// 두 가지로 실행돼요.
// 1) VS Code 확장이 실행: chanelu-desktop <sheet.png> <socket-path> [size speed sleepAfterSeconds]
//    확장이 유닉스 소켓으로 한 줄짜리 명령을 보내요: typing | saved | pet | sleep | config <size> <speed> <sleep> | quit
//    연결된 VS Code 창이 하나도 없으면 몇 초 뒤 스스로 종료해요.
// 2) 혼자 실행 (Chanelu.app 더블클릭, 인자 없음): 메뉴 막대 아이콘으로 조작하고,
//    키보드·마우스를 한동안 안 쓰면 잠들어요. 같은 소켓을 열어 두니 VS Code 확장도 이 샤네루에 붙어요.
import AppKit

signal(SIGPIPE, SIG_IGN)

let args = CommandLine.arguments
let standalone = args.count < 3
let defaults = UserDefaults.standard
let sheetPath = standalone ? (Bundle.main.path(forResource: "sheet", ofType: "png") ?? "sheet.png") : args[1]
let sockPath = standalone
    ? (ProcessInfo.processInfo.environment["CHANELU_SOCKET"] ?? "/tmp/chanelu-\(getuid()).sock") // 테스트용으로 바꿀 수 있어요
    : args[2]
var cfgSize: CGFloat = standalone
    ? CGFloat(defaults.object(forKey: "size") as? Double ?? 96)
    : (args.count > 3 ? CGFloat(Double(args[3]) ?? 96) : 96)
var cfgSpeed: CGFloat = args.count > 4 ? CGFloat(Double(args[4]) ?? 60) : 60
var cfgSleep: Double = standalone
    ? (defaults.object(forKey: "sleepAfter") as? Double ?? 120)
    : (args.count > 5 ? (Double(args[5]) ?? 120) : 120)

// ---- 한 번에 하나만 실행 (VS Code 창이 여러 개여도 chanelu는 한 마리) ----
func unixAddr(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8.prefix(100))
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.enumerated() { raw[i] = b }
        raw[bytes.count] = 0
    }
    return addr
}

/// 이미 떠 있는 샤네루(VS Code가 띄운 것)에게 한 줄 보내기
func sendLine(_ path: String, _ line: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var addr = unixAddr(path)
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard ok == 0 else { return }
    _ = (line + "\n").withCString { write(fd, $0, strlen($0)) }
}

let lockFd = open(sockPath + ".lock", O_CREAT | O_RDWR, 0o600)
if lockFd < 0 { exit(0) }
if flock(lockFd, LOCK_EX | LOCK_NB) != 0 {
    // VS Code가 띄운 샤네루는 그대로 두고 조용히 양보해요.
    // 앱(혼자 실행)은 VS Code 샤네루에게 자리를 넘겨받아요. VS Code 확장은 잠시 뒤 앱 샤네루에 다시 붙어요.
    guard standalone else { exit(0) }
    sendLine(sockPath, "quit")
    var got = false
    for _ in 0..<30 {
        usleep(100_000)
        if flock(lockFd, LOCK_EX | LOCK_NB) == 0 { got = true; break }
    }
    if !got { exit(0) } // 다른 앱 샤네루가 이미 떠 있으면 그대로 둬요
}

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
        case "work":
            // AI(Claude, Codex 등)가 일하는 중: 깨어 있고, 쉬고 있었으면 같이 바쁘게 돌아다녀요
            lastInput = CACurrentMediaTime()
            if mode == .sleeping { wakeUp { [unowned self] in self.startWalk() } }
            else if mode == .idle { startWalk() }
        case "done":
            // AI 작업 끝: 하트 + 깡충
            lastInput = CACurrentMediaTime()
            if !held {
                popup("❤️", color: nil)
                wakeUp { [unowned self] in self.trick(.hop) }
            }
        case "attention":
            // AI가 확인/승인을 기다려요: "!" + 손 흔들기, 두 발 서기
            lastInput = CACurrentMediaTime()
            if !held {
                popup("❗️", color: nil)
                wakeUp { [unowned self] in
                    self.mode = .busy
                    self.play(.wave, dur: 0.11, onDone: { [unowned self] in self.trick(.beg) })
                }
            }
        case "saved":
            lastInput = CACurrentMediaTime()
            if !held { wakeUp { [unowned self] in self.trick(.hop) } }
        case "pet":
            if !held { pet() }
        case "sleep":
            fallAsleep()
        case "config" where p.count >= 4 && !standalone: // 혼자 실행 중이면 메뉴 설정이 우선
            cfgSize = CGFloat(Double(p[1]) ?? Double(cfgSize))
            cfgSpeed = CGFloat(Double(p[2]) ?? Double(cfgSpeed))
            cfgSleep = Double(p[3]) ?? cfgSleep
            applySize()
        case "quit" where !standalone: // 혼자 실행한 앱은 메뉴의 종료로만 꺼져요
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

        if standalone {
            // 혼자 실행할 땐 키보드·마우스를 쓴 시각을 기준으로 자고 깨요
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            lastInput = max(lastInput, now - idle)
            if mode == .sleeping && idle < 0.5 { wakeUp { [unowned self] in self.startIdle() } }
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
    let onLine: (String, Int32) -> Void
    var listenSrc: DispatchSourceRead?
    var clients: [Int32: Client] = [:]
    var emptySince: Double? = CACurrentMediaTime()

    init(path: String, onLine: @escaping (String, Int32) -> Void) {
        self.onLine = onLine
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = unixAddr(path)
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
                self.onLine(line.trimmingCharacters(in: .whitespacesAndNewlines), fd)
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

// ---- 메뉴 막대 (혼자 실행할 때만) ----
final class MenuTarget: NSObject {
    let ctl: Controller
    var sizeItems: [NSMenuItem] = []
    var sleepItems: [NSMenuItem] = []
    init(ctl: Controller) { self.ctl = ctl }

    @objc func pet() { ctl.pet() }
    @objc func sleep() { ctl.fallAsleep() }
    @objc func quitApp() { quit() }
    @objc func setSize(_ item: NSMenuItem) {
        cfgSize = CGFloat(item.tag)
        defaults.set(Double(item.tag), forKey: "size")
        ctl.applySize()
        refresh()
    }
    @objc func setSleep(_ item: NSMenuItem) {
        cfgSleep = Double(item.tag)
        defaults.set(Double(item.tag), forKey: "sleepAfter")
        refresh()
    }
    func refresh() {
        for i in sizeItems { i.state = CGFloat(i.tag) == cfgSize ? .on : .off }
        for i in sleepItems { i.state = Double(i.tag) == cfgSleep ? .on : .off }
    }
}

var statusItem: NSStatusItem?
var menuTarget: MenuTarget?

func setupMenuBar(_ ctl: Controller) {
    let t = MenuTarget(ctl: ctl)
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let icon = NSImage(cgImage: ctl.frames[Row.idle.rawValue][0], size: NSSize(width: 15, height: 20))
    item.button?.image = icon
    item.button?.toolTip = "꽃개 샤네루"

    let menu = NSMenu()
    func add(_ title: String, _ action: Selector, to m: NSMenu = menu, tag: Int = 0, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = t
        i.tag = tag
        m.addItem(i)
        return i
    }
    let header = NSMenuItem(title: "꽃개 샤네루", action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    menu.addItem(.separator())
    _ = add("쓰다듬기", #selector(MenuTarget.pet))
    _ = add("재우기", #selector(MenuTarget.sleep))

    let sizeMenu = NSMenu()
    for (name, v) in [("작게", 72), ("보통", 96), ("크게", 128), ("아주 크게", 160)] {
        t.sizeItems.append(add(name, #selector(MenuTarget.setSize(_:)), to: sizeMenu, tag: v))
    }
    let sizeRoot = NSMenuItem(title: "크기", action: nil, keyEquivalent: "")
    sizeRoot.submenu = sizeMenu
    menu.addItem(sizeRoot)

    let sleepMenu = NSMenu()
    for (name, v) in [("1분", 60), ("2분", 120), ("5분", 300), ("10분", 600), ("안 잠", 0)] {
        t.sleepItems.append(add(name, #selector(MenuTarget.setSleep(_:)), to: sleepMenu, tag: v))
    }
    let sleepRoot = NSMenuItem(title: "안 움직이면 잠들기", action: nil, keyEquivalent: "")
    sleepRoot.submenu = sleepMenu
    menu.addItem(sleepRoot)

    menu.addItem(.separator())
    _ = add("종료", #selector(MenuTarget.quitApp), key: "q")
    item.menu = menu
    t.refresh()
    statusItem = item
    menuTarget = t
}

// ---- 시작 ----
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // Dock 아이콘 없이
let ctl = Controller(frames: loadFrames())
let server = Server(path: sockPath) { line, fd in
    if line == "version" {
        // VS Code 확장이 버전을 물어보면 답해요. 예전 버전이면 확장이 새 버전으로 바꿔 띄워요.
        let reply = "version \(helperVersion) \(standalone ? "app" : "ext")\n"
        _ = reply.withCString { write(fd, $0, strlen($0)) }
    } else {
        ctl.handle(line)
    }
}
if standalone { setupMenuBar(ctl) }

let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
    ctl.tick()
    // VS Code가 띄운 경우에만, 연결된 창이 없으면 종료
    if !standalone, let t = server.emptySince, CACurrentMediaTime() - t > 5 { quit() }
}
RunLoop.main.add(timer, forMode: .common)
app.run()
