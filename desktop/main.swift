// chanelu 데스크톱 펫: 투명 창으로 화면 아래(Dock 위)를 돌아다녀요.
//
// 두 가지로 실행돼요.
// 1) VS Code 확장이 실행: chanelu-desktop <sheet.png | pet.json> <socket-path> [size speed sleepAfterSeconds]
//    확장이 유닉스 소켓으로 한 줄짜리 명령을 보내요: typing | saved | pet | sleep | config <size> <speed> <sleep> | quit
//    연결된 VS Code 창이 하나도 없으면 몇 초 뒤 스스로 종료해요.
// 2) 혼자 실행 (Chanelu.app 더블클릭, 인자 없음): 메뉴 막대 아이콘으로 조작하고,
//    키보드·마우스를 한동안 안 쓰면 잠들어요. 같은 소켓을 열어 두니 VS Code 확장도 이 샤네루에 붙어요.
//
// 샤네루 말고 다른 펫도 띄울 수 있어요: pet.json + 스프라이트 시트 (docs/pet-format.md).
// 혼자 실행할 때 펫을 찾는 순서: CHANELU_PET 환경 변수 → 앱 옆 PetData/pet.json 또는 pet.json
// → 메뉴 "펫 바꾸기"에서 마지막으로 고른 펫 → 기본 샤네루.
// 앱 옆에서 찾은 펫은 펫 목록(~/Library/Application Support/Chanelu/Pets)에 복사돼서 계속 고를 수 있어요.
// 펫 파일(.chanelupet = pet.json + 시트를 묶은 zip)을 더블클릭해도 목록에 들어가요.
import AppKit
import CryptoKit

signal(SIGPIPE, SIG_IGN)

let args = CommandLine.arguments
let standalone = args.count < 3
let defaults = UserDefaults.standard
let builtinSheet = standalone ? (Bundle.main.path(forResource: "sheet", ofType: "png") ?? "sheet.png") : args[1]
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
    // 앱(혼자 실행)은 이미 떠 있는 샤네루(VS Code든 다른 펫 앱이든)에게서 자리를 넘겨받아요.
    // 새로 받은 펫 앱을 열면 그 펫이 목록에 들어가야 하니까요. VS Code 확장은 잠시 뒤 앱 샤네루에 다시 붙어요.
    guard standalone else { exit(0) }
    sendLine(sockPath, "quit")      // VS Code가 띄운 샤네루
    sendLine(sockPath, "takeover")  // 혼자 실행한 앱 (0.3.0부터)
    var got = false
    for _ in 0..<30 {
        usleep(100_000)
        if flock(lockFd, LOCK_EX | LOCK_NB) == 0 { got = true; break }
    }
    if !got { exit(0) } // 예전 버전 앱이 떠 있으면 그대로 둬요
}

func quit() -> Never {
    unlink(sockPath)
    exit(0)
}

// ---- 펫 (스프라이트 시트 + 동작) ----
// 프레임 번호는 시트를 왼쪽 위부터 가로로 읽은 순서예요: 번호 = 행 * 열개수 + 열.
// dur이 nil이면 동작마다 정해진 기본 속도를 써요 (샤네루가 원래 움직이던 속도).
struct Clip {
    var frames: [Int]
    var dur: Double?
    var flip = false
}

struct Pet {
    var name: String
    var fw: Int, fh: Int
    var clips: [String: Clip]
    var images: [Int: CGImage]
    var builtin: Bool
    /// pet.json 이 있던 폴더
    var source: URL?
    /// 펫 목록 안의 이름표 (기본 샤네루, 목록에 없는 펫은 nil)
    var id: String? = nil

    func has(_ n: String) -> Bool { clips[n] != nil }
    /// 이름 중 처음 있는 동작
    func first(_ names: [String]) -> String? { names.first { clips[$0] != nil } }
}

struct PetError: Error { let message: String }

/// pet.json에 이름이 없을 때
let defaultPetName = "쵸콘이"

func loadSheet(_ path: String) throws -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw PetError(message: "이미지를 읽을 수 없어요: \((path as NSString).lastPathComponent)")
    }
    return img
}

/// 시트에서 쓰는 프레임만 잘라 둬요. 시트 밖 번호는 빼요.
func cutFrames(_ sheet: CGImage, fw: Int, fh: Int, cols: Int, clips: inout [String: Clip]) -> [Int: CGImage] {
    let rows = sheet.height / fh
    let total = cols * rows
    var images: [Int: CGImage] = [:]
    for (k, var c) in clips {
        c.frames = c.frames.filter { $0 >= 0 && $0 < total && ($0 % cols + 1) * fw <= sheet.width }
        if c.frames.isEmpty { clips[k] = nil; continue }
        clips[k] = c
        for i in c.frames where images[i] == nil {
            images[i] = sheet.cropping(to: CGRect(x: (i % cols) * fw, y: (i / cols) * fh, width: fw, height: fh))
        }
    }
    return images.compactMapValues { $0 }
}

/// 걷기는 오른쪽/왼쪽 두 방향이 필요해요. 한쪽만 있으면 좌우를 뒤집어서 써요.
func resolveWalk(_ clips: inout [String: Clip], facingLeft: Bool) {
    let walk = clips.removeValue(forKey: "walk")
    var right = clips["walkRight"], left = clips["walkLeft"]
    if let w = walk {
        if facingLeft { if left == nil { left = w } } else { if right == nil { right = w } }
    }
    if right == nil, var l = left { l.flip.toggle(); right = l }
    if left == nil, var r = right { r.flip.toggle(); left = r }
    clips["walkRight"] = right
    clips["walkLeft"] = left
}

/// 잠들기: sleepStart(눕기) → sleep(자는 중 반복) → wake(일어나기). wake가 없으면 sleepStart를 거꾸로.
func resolveSleep(_ clips: inout [String: Clip]) {
    if clips["wake"] == nil, var s = clips["sleepStart"], s.frames.count > 1 {
        s.frames = Array(s.frames.dropLast().reversed())
        clips["wake"] = s
    }
}

/// 기본 샤네루: 8열 x 11행, 행마다 동작 하나
func chaneluPet(sheetPath: String) throws -> Pet {
    func row(_ r: Int, _ cols: [Int] = Array(0...7)) -> Clip { Clip(frames: cols.map { r * 8 + $0 }) }
    var clips: [String: Clip] = [
        "idle": row(0), "look": row(1), "happy": row(2), "wave": row(3), "jump": row(4),
        "walkRight": row(5), "walkLeft": row(6), "beg": row(7), "sit": row(8), "sitBlink": row(9),
        "sleepStart": row(10, Array(0...4)), "sleep": row(10, Array(4...7)), "wake": row(10, [3, 2, 1, 0]),
        "drag": row(7, [2, 3, 4, 3]),
    ]
    let sheet = try loadSheet(sheetPath)
    let images = cutFrames(sheet, fw: 110, fh: 145, cols: 8, clips: &clips)
    return Pet(name: "꽃개 샤네루", fw: 110, fh: 145, clips: clips, images: images, builtin: true, source: nil)
}

/// pet.json 읽기. 경로가 폴더면 그 안의 pet.json.
func loadPetJSON(_ url: URL) throws -> Pet {
    var url = url
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
        url = url.appendingPathComponent("pet.json")
    }
    guard let data = try? Data(contentsOf: url) else { throw PetError(message: "pet.json을 찾을 수 없어요") }
    guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        throw PetError(message: "pet.json 형식이 올바르지 않아요")
    }
    func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
    if let v = num(j["version"]), v > 1 { throw PetError(message: "더 새 버전의 펫 파일이에요. 앱을 업데이트해 주세요") }
    guard let sprite = j["sprite"] as? String, !sprite.isEmpty,
          let fwD = num(j["frameWidth"]), let fhD = num(j["frameHeight"]) else {
        throw PetError(message: "pet.json에 sprite, frameWidth, frameHeight가 필요해요")
    }
    let fw = Int(fwD), fh = Int(fhD)
    guard fw > 0, fh > 0, fw <= 4096, fh <= 4096 else { throw PetError(message: "프레임 크기가 올바르지 않아요") }
    guard !sprite.hasPrefix("/"), !sprite.split(separator: "/").contains("..") else {
        throw PetError(message: "sprite는 pet.json과 같은 폴더 안의 파일이어야 해요")
    }
    let dir = url.deletingLastPathComponent()
    let sheet = try loadSheet(dir.appendingPathComponent(sprite).path)
    let cols = num(j["columns"]).map { Int($0) } ?? (sheet.width / fw)
    guard cols > 0, sheet.height >= fh else { throw PetError(message: "이미지가 프레임 크기보다 작아요") }

    var clips: [String: Clip] = [:]
    for (k, v) in (j["animations"] as? [String: Any]) ?? [:] {
        guard let a = v as? [String: Any], let fr = a["frames"] as? [Any] else { continue }
        let frames = fr.compactMap { num($0).map { Int($0) } }
        let fps = num(a["fps"]).flatMap { $0 > 0 ? $0 : nil }
        clips[k] = Clip(frames: frames, dur: fps.map { 1 / min(60, $0) }, flip: (a["flip"] as? Bool) ?? false)
    }
    resolveWalk(&clips, facingLeft: (j["walkFacing"] as? String) == "left")
    resolveSleep(&clips)
    let images = cutFrames(sheet, fw: fw, fh: fh, cols: cols, clips: &clips)
    if clips["idle"] == nil {
        // 가만히 있는 동작이 없으면 아무 동작의 첫 프레임으로
        guard let any = clips.keys.sorted().first.flatMap({ clips[$0] }) else {
            throw PetError(message: "시트 안에 있는 프레임이 하나도 없어요. 프레임 크기와 번호를 확인해 주세요")
        }
        clips["idle"] = Clip(frames: [any.frames[0]], dur: nil, flip: any.flip)
    }
    let name = (j["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultPetName
    return Pet(name: name, fw: fw, fh: fh, clips: clips, images: images, builtin: false, source: dir)
}

// ---- 펫 찾기 ----
let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Chanelu", isDirectory: true)
/// 펫 목록: Pets/<id>/pet.json + 시트. id는 파일 내용으로 정해서 같은 펫은 한 번만 들어가요.
let petsDir = supportDir.appendingPathComponent("Pets", isDirectory: true)

/// 인터넷에서 받은 앱은 macOS가 임시 위치로 옮겨 실행해요(App Translocation). 그럴 때도 원래 위치를 찾아요.
func originalAppURL() -> URL {
    let url = Bundle.main.bundleURL
    typealias IsFn = @convention(c) (CFURL, UnsafeMutablePointer<DarwinBoolean>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> DarwinBoolean
    typealias OrigFn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
    guard let h = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
          let isSym = dlsym(h, "SecTranslocateIsTranslocatedURL"),
          let origSym = dlsym(h, "SecTranslocateCreateOriginalPathForURL") else { return url }
    var translocated: DarwinBoolean = false
    guard unsafeBitCast(isSym, to: IsFn.self)(url as CFURL, &translocated, nil).boolValue, translocated.boolValue,
          let orig = unsafeBitCast(origSym, to: OrigFn.self)(url as CFURL, nil) else { return url }
    return orig.takeRetainedValue() as URL
}

/// 펫을 못 읽었을 때 알려 줄 말 (혼자 실행할 때 창으로 보여요)
var loadWarning: String?

enum DupChoice { case replace, add, cancel }

/// 이름이 같은 펫이 이미 목록에 있을 때 물어봐요
func askDuplicate(_ name: String) -> DupChoice {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = "'\(name)'이(가) 이미 있어요."
    a.informativeText = "새로 받은 펫으로 바꿀까요?\n따로 추가하면 둘 다 펫 목록에 남아요."
    a.addButton(withTitle: "바꾸기")
    a.addButton(withTitle: "따로 추가하기")
    a.addButton(withTitle: "취소")
    switch a.runModal() {
    case .alertFirstButtonReturn: return .replace
    case .alertSecondButtonReturn: return .add
    default: return .cancel
    }
}

/// 펫을 목록에 넣고 id를 돌려줘요. 내용까지 똑같은 펫이 있으면 그대로 (isNew = false).
/// 이름만 같은 펫이 있으면 ask로 물어봐요: 바꾸기(예전 것을 지움) / 따로 추가 / 취소(nil).
func addToLibrary(_ dir: URL, name: String, ask: (String) -> DupChoice) throws -> (id: String, isNew: Bool)? {
    let fm = FileManager.default
    let json = dir.appendingPathComponent("pet.json")
    let data = try Data(contentsOf: json)
    guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let sprite = j["sprite"] as? String else { throw PetError(message: "pet.json을 읽을 수 없어요") }
    let spriteData = try Data(contentsOf: dir.appendingPathComponent(sprite))
    let digest = SHA256.hash(data: data + spriteData)
    let id = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    let dst = petsDir.appendingPathComponent(id, isDirectory: true)
    if fm.fileExists(atPath: dst.appendingPathComponent("pet.json").path) { return (id, false) }
    var replaceID: String?
    if let same = libraryEntries().last(where: { $0.name == name }) {
        switch ask(name) {
        case .replace: replaceID = same.id
        case .add: break
        case .cancel: return nil
        }
    }
    let tmp = petsDir.appendingPathComponent(".\(id).tmp", isDirectory: true)
    try? fm.removeItem(at: tmp)
    let spriteDst = tmp.appendingPathComponent(sprite)
    try fm.createDirectory(at: spriteDst.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: tmp.appendingPathComponent("pet.json"))
    try spriteData.write(to: spriteDst)
    try? fm.removeItem(at: dst)
    try fm.moveItem(at: tmp, to: dst)
    if let r = replaceID { try? fm.removeItem(at: petsDir.appendingPathComponent(r, isDirectory: true)) }
    return (id, true)
}

struct LibraryEntry { let id: String; let name: String; let added: Date }

/// 메뉴에 보일 이름. 같은 이름이 여러 개면 두 번째부터 "이름 (2)"처럼.
func displayNames(_ lib: [LibraryEntry]) -> [String: String] {
    var seen: [String: Int] = [:]
    var out: [String: String] = [:]
    for e in lib {
        let n = (seen[e.name] ?? 0) + 1
        seen[e.name] = n
        out[e.id] = n == 1 ? e.name : "\(e.name) (\(n))"
    }
    return out
}

/// 목록에 있는 펫들 (넣은 순서)
func libraryEntries() -> [LibraryEntry] {
    let fm = FileManager.default
    guard let dirs = try? fm.contentsOfDirectory(at: petsDir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else { return [] }
    return dirs.compactMap { d -> LibraryEntry? in
        guard let data = try? Data(contentsOf: d.appendingPathComponent("pet.json")),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let name = (j["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultPetName
        let added = (try? d.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        return LibraryEntry(id: d.lastPathComponent, name: name, added: added)
    }.sorted { $0.added < $1.added }
}

func loadLibraryPet(_ id: String) throws -> Pet {
    var p = try loadPetJSON(petsDir.appendingPathComponent(id, isDirectory: true))
    p.id = id
    return p
}

func findPet() -> Pet {
    func report(_ path: String, _ e: Error) {
        let msg = (e as? PetError)?.message ?? e.localizedDescription
        loadWarning = msg
        FileHandle.standardError.write("pet: \(path): \(msg)\n".data(using: .utf8)!)
    }
    if !standalone {
        // VS Code 확장: 첫 인자가 pet.json이면 그 펫, 아니면 샤네루 시트
        if args[1].hasSuffix(".json") {
            do { return try loadPetJSON(URL(fileURLWithPath: args[1])) } catch { report(args[1], error) }
        }
    } else {
        if let env = ProcessInfo.processInfo.environment["CHANELU_PET"], !env.isEmpty {
            do { return try loadPetJSON(URL(fileURLWithPath: env)) } catch { report(env, error) }
        }
        // 앱 옆에 새 펫이 있으면: 목록에 넣고 그 펫으로 바꿔요. (이름이 같은 펫이 있으면 물어봐요)
        // 이미 목록에 있는 펫이거나 취소했으면 메뉴에서 마지막으로 고른 펫을 그대로 써요.
        let beside = originalAppURL().deletingLastPathComponent()
        for rel in ["PetData/pet.json", "pet.json"] {
            let u = beside.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: u.path) else { continue }
            do {
                var p = try loadPetJSON(u)
                guard let dir = p.source else { return p }
                let result: (id: String, isNew: Bool)?
                do { result = try addToLibrary(dir, name: p.name, ask: askDuplicate) } catch { return p } // 복사 못 하면 이번만 띄워요
                if let added = result, added.isNew || defaults.string(forKey: "pet") == nil {
                    p.id = added.id
                    defaults.set(added.id, forKey: "pet")
                    return p
                }
            } catch { report(u.path, error) }
            break
        }
        // 마지막으로 고른 펫
        if let id = defaults.string(forKey: "pet"), !id.isEmpty {
            do { return try loadLibraryPet(id) } catch { report(id, error) }
        }
    }
    do { return try chaneluPet(sheetPath: builtinSheet) } catch {
        FileHandle.standardError.write("cannot load sheet\n".data(using: .utf8)!)
        exit(3)
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
        var clip: Clip
        var dur: Double
        var loop: Bool
        var onDone: (() -> Void)?
        var alternate = false // 반복할 때마다 좌우를 바꿔요 (갸우뚱을 왼쪽, 오른쪽 번갈아)
    }

    var current: Pet
    let window: PupWindow
    let view: PupView
    let dog = CALayer()
    let headroom: CGFloat = 44

    var w: CGFloat = 0, h: CGFloat = 0
    var x: CGFloat = 0, y: CGFloat = 0, vy: CGFloat = 0
    var mode = Mode.idle
    var anim: Anim?
    var fi = 0, ft = 0.0
    /// 지금 동작을 좌우로 뒤집어 그리기 (갸우뚱을 오른쪽으로도)
    var mirror = false
    var target: CGFloat = 0, dir: CGFloat = 1
    var restUntil = 0.0
    var lastInput = CACurrentMediaTime()
    var zzz = 0.0
    var prev = CACurrentMediaTime()
    var dragOffset = CGPoint.zero
    var dragMoved = false

    init(pet: Pet) {
        current = pet
        window = PupWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        view = PupView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear
        dog.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "transform": NSNull()]
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
        w = CGFloat(current.fw) * cfgSize / CGFloat(current.fh)
        window.setContentSize(NSSize(width: w, height: h + headroom))
        dog.transform = CATransform3DIdentity
        dog.frame = CGRect(x: 0, y: 0, width: w, height: h)
        if let a = anim { setFrame(a.clip, a.clip.frames[fi]) }
    }

    /// 다른 펫으로 바꾸기 (메뉴의 펫 불러오기)
    func setPet(_ p: Pet) {
        current = p
        anim = nil
        applySize()
        startIdle()
    }

    // ---- 애니메이션 ----
    func setFrame(_ c: Clip, _ i: Int) {
        guard let img = current.images[i] else { return }
        dog.contents = img
        dog.transform = c.flip != mirror ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
    }

    /// 동작 재생. 펫 파일에 fps가 있으면 그 속도, 없으면 동작별 기본 속도(dur).
    /// mirror: 좌우로 뒤집어서 재생 (갸우뚱 시트는 한쪽으로만 기울어 있어서 반대쪽은 뒤집어 써요)
    func play(_ name: String, dur: Double, loop: Bool = false, mirror: Bool = false, onDone: (() -> Void)? = nil) {
        guard let c = current.clips[name] ?? current.clips["idle"] else { return }
        anim = Anim(clip: c, dur: c.dur ?? dur, loop: loop, onDone: onDone, alternate: name == "look")
        fi = 0; ft = 0
        self.mirror = mirror
        setFrame(c, c.frames[0])
    }

    func advance(_ dt: Double) {
        guard var a = anim else { return }
        ft += dt
        while ft >= a.dur {
            ft -= a.dur
            fi += 1
            if fi >= a.clip.frames.count {
                if a.loop {
                    fi = 0
                    if a.alternate { mirror.toggle() }
                } else {
                    fi = a.clip.frames.count - 1
                    let done = a.onDone
                    a.onDone = nil
                    a.dur = .infinity
                    anim = a
                    setFrame(a.clip, a.clip.frames[fi])
                    done?()
                    return
                }
            }
            setFrame(a.clip, a.clip.frames[fi])
        }
    }

    // ---- 상태 ----
    /// 시트에 없는 동작은 빼고, 있는 동작 중에서 골라요
    func pick(_ names: [String], or fallback: String = "idle") -> String {
        names.filter { current.has($0) }.randomElement() ?? fallback
    }

    func startIdle() {
        mode = .idle
        restUntil = CACurrentMediaTime() + 2 + Double.random(in: 0...5)
        let name = pick(["idle", "idle", "look", "happy", "sit", "sitBlink"])
        // 갸우뚱은 반은 뒤집어서 오른쪽으로도 기울게
        play(name, dur: 0.16, loop: true, mirror: name == "look" && Bool.random())
    }

    func startWalk() {
        // 걷는 동작이 없는 펫은 제자리에 있어요
        guard current.has("walkRight") else { startIdle(); return }
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
            play(dir > 0 ? "walkRight" : "walkLeft", dur: 0.1, loop: true)
            return
        }
        let maxX = sf.maxX - w
        target = CGFloat.random(in: sf.minX...max(sf.minX + 1, maxX))
        // 너무 가까우면 좀 더 멀리
        if abs(target - x) < 60 { target = x < (sf.minX + maxX) / 2 ? min(maxX, x + 300) : max(sf.minX, x - 300) }
        dir = target > x ? 1 : -1
        play(dir > 0 ? "walkRight" : "walkLeft", dur: 0.1, loop: true)
    }

    func trick(_ name: String) {
        mode = .busy
        play(name, dur: 0.11, onDone: { [unowned self] in self.startIdle() })
    }

    /// 깡충 (없으면 클릭 반응, 그것도 없으면 가만히)
    var jump: String { current.first(["jump", "react", "happy"]) ?? "idle" }

    func fallAsleep() {
        if mode == .sleeping || mode == .dragging || mode == .falling { return }
        mode = .busy
        let sleepLoop = { [unowned self] in
            self.mode = .sleeping
            self.play(self.current.has("sleep") ? "sleep" : "idle", dur: 0.45, loop: true)
        }
        if current.has("sleepStart") { play("sleepStart", dur: 0.22, onDone: sleepLoop) } else { sleepLoop() }
    }

    func wakeUp(_ then: @escaping () -> Void) {
        if mode != .sleeping { then(); return }
        guard current.has("wake") else { then(); return }
        mode = .busy
        play("wake", dur: 0.15, onDone: then)
    }

    func pet() {
        lastInput = CACurrentMediaTime()
        popup("❤️", color: nil)
        wakeUp { [unowned self] in self.trick(self.pick(["react", "jump", "wave", "beg", "happy"], or: self.jump)) }
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
            play(current.first(["drag", "react", "jump"]) ?? "idle", dur: 0.12, loop: true)
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
                wakeUp { [unowned self] in self.trick(self.jump) }
            }
        case "attention":
            // AI가 확인/승인을 기다려요: "!" + 손 흔들기, 두 발 서기
            lastInput = CACurrentMediaTime()
            if !held {
                popup("❗️", color: nil)
                wakeUp { [unowned self] in
                    self.mode = .busy
                    let first = self.current.first(["wave", "react"]) ?? self.jump
                    self.play(first, dur: 0.11, onDone: { [unowned self] in self.trick(self.current.first(["beg"]) ?? "idle") })
                }
            }
        case "saved":
            lastInput = CACurrentMediaTime()
            if !held { wakeUp { [unowned self] in self.trick(self.jump) } }
        case "pet":
            if !held { pet() }
        case "sleep":
            fallAsleep()
        case "config" where p.count >= 4 && !standalone: // 혼자 실행 중이면 메뉴 설정이 우선
            cfgSize = CGFloat(Double(p[1]) ?? Double(cfgSize))
            cfgSpeed = CGFloat(Double(p[2]) ?? Double(cfgSpeed))
            cfgSleep = Double(p[3]) ?? cfgSleep
            applySize()
        case "quit" where !standalone: // 혼자 실행한 앱은 메뉴의 종료나 takeover로만 꺼져요
            quit()
        case "takeover": // 다른 펫 앱이 새로 열렸어요: 자리를 넘겨줘요
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
            if y <= sf.minY { y = sf.minY; vy = 0; trick(jump) }
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

// ---- 펫 파일 (.chanelupet) ----
/// zip 풀기. 폴더 밖으로 나가는 경로가 들어 있으면 거절해요.
func unzipPet(_ file: URL, to dir: URL) throws {
    func run(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw PetError(message: "펫 파일이 손상됐어요. 다시 받아 주세요") }
        return String(decoding: data, as: UTF8.self)
    }
    let entries = try run(["-Z1", file.path]).split(separator: "\n").map(String.init)
    guard !entries.isEmpty, entries.count < 100 else { throw PetError(message: "펫 파일이 올바르지 않아요") }
    for e in entries where e.hasPrefix("/") || e.split(separator: "/").contains("..") {
        throw PetError(message: "펫 파일이 올바르지 않아요")
    }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    _ = try run(["-q", "-o", file.path, "-d", dir.path])
}

/// 펫 파일을 열어 목록에 넣고 그 펫으로 바꿔요. 이름이 같은 펫이 있으면 물어봐요.
func openPetFile(_ url: URL, ctl: Controller) {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("chanelupet-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: tmp) }
    do {
        try unzipPet(url, to: tmp)
        // pet.json이 맨 위에 있거나, 폴더 하나 안에 있어요
        var dir = tmp
        if !fm.fileExists(atPath: tmp.appendingPathComponent("pet.json").path),
           let sub = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
               .first(where: { fm.fileExists(atPath: $0.appendingPathComponent("pet.json").path) }) {
            dir = sub
        }
        let p = try loadPetJSON(dir)
        guard let added = try addToLibrary(dir, name: p.name, ask: askDuplicate) else { return }
        let lp = try loadLibraryPet(added.id)
        defaults.set(added.id, forKey: "pet")
        ctl.setPet(lp)
        setupMenuBar(ctl)
    } catch {
        alert("펫을 추가하지 못했어요", (error as? PetError)?.message ?? error.localizedDescription)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let ctl: Controller
    init(ctl: Controller) { self.ctl = ctl }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard standalone else { return }
        for u in urls where u.pathExtension.lowercased() == "chanelupet" { openPetFile(u, ctl: ctl) }
    }
}

// ---- 응용 프로그램 폴더로 옮기기 ----
/// 다운로드 폴더 같은 데서 실행했으면, 응용 프로그램 폴더로 옮길지 한 번 물어봐요.
/// 앱이 한 군데에 있어야 펫 파일을 더블클릭했을 때 늘 같은 앱이 열려요.
func offerMoveToApplications() {
    let fm = FileManager.default
    let here = originalAppURL()
    let path = here.standardizedFileURL.path
    guard here.pathExtension == "app",
          !path.hasPrefix("/Applications/"),
          !path.hasPrefix(NSHomeDirectory() + "/Applications/"),
          !defaults.bool(forKey: "dontAskMove") else { return }
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = "샤네루를 응용 프로그램 폴더로 옮길까요?"
    a.informativeText = "옮겨 두면 펫 파일(.chanelupet)을 더블클릭해서 펫을 추가할 수 있고, 받은 폴더를 지워도 괜찮아요."
    a.addButton(withTitle: "옮기기")
    a.addButton(withTitle: "이대로 쓰기")
    guard a.runModal() == .alertFirstButtonReturn else {
        defaults.set(true, forKey: "dontAskMove")
        return
    }
    let dst = URL(fileURLWithPath: "/Applications/Chanelu.app")
    do {
        if fm.fileExists(atPath: dst.path) { try fm.trashItem(at: dst, resultingItemURL: nil) } // 예전 버전은 휴지통으로
        try fm.copyItem(at: here, to: dst)
    } catch {
        alert("옮기지 못했어요", "응용 프로그램 폴더에 쓸 수 없어요. 직접 끌어다 옮겨 주세요.\n(\(error.localizedDescription))")
        return
    }
    try? fm.trashItem(at: here, resultingItemURL: nil) // 원래 자리의 앱은 휴지통으로 (못 지우면 그대로)
    // 옮긴 앱을 새로 띄우면 이 앱에게서 자리를 넘겨받아요
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-n", dst.path]
    try? p.run()
}

// ---- 메뉴 막대 (혼자 실행할 때만) ----
func alert(_ title: String, _ text: String) {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    a.runModal()
}

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
    /// 펫 바꾸기: 목록에서 고른 펫으로 (빈 id는 기본 샤네루)
    @objc func selectPet(_ item: NSMenuItem) {
        let id = item.representedObject as? String ?? ""
        do {
            let p = id.isEmpty ? try chaneluPet(sheetPath: builtinSheet) : try loadLibraryPet(id)
            defaults.set(id, forKey: "pet")
            ctl.setPet(p)
            setupMenuBar(ctl)
        } catch {
            alert("펫을 바꾸지 못했어요", (error as? PetError)?.message ?? error.localizedDescription)
        }
    }
    @objc func removePet(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, !id.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "\(item.title)을(를) 목록에서 지울까요?"
        a.informativeText = "받아 둔 펫 폴더가 있으면, 그 폴더의 앱을 다시 실행해서 목록에 넣을 수 있어요."
        a.addButton(withTitle: "지우기")
        a.addButton(withTitle: "취소")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.removeItem(at: petsDir.appendingPathComponent(id, isDirectory: true))
        setupMenuBar(ctl)
    }
    func refresh() {
        for i in sizeItems { i.state = CGFloat(i.tag) == cfgSize ? .on : .off }
        for i in sleepItems { i.state = Double(i.tag) == cfgSleep ? .on : .off }
    }
}

var statusItem: NSStatusItem?
var menuTarget: MenuTarget?

/// 메뉴 막대 아이콘과 메뉴. 펫을 바꾸면 다시 만들어요.
func setupMenuBar(_ ctl: Controller) {
    let t = MenuTarget(ctl: ctl)
    let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let p = ctl.current
    if let first = p.clips["idle"]?.frames.first, let img = p.images[first] {
        // 높이 20pt에 맞추고, 너무 넓으면 22pt로 줄여요
        let ih: CGFloat = 20, iw = min(22, ih * CGFloat(p.fw) / CGFloat(p.fh))
        item.button?.image = NSImage(cgImage: img, size: NSSize(width: iw, height: iw * CGFloat(p.fh) / CGFloat(p.fw)))
    }
    item.button?.toolTip = p.name

    let menu = NSMenu()
    func add(_ title: String, _ action: Selector, to m: NSMenu = menu, tag: Int = 0, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = t
        i.tag = tag
        m.addItem(i)
        return i
    }
    let header = NSMenuItem(title: p.name, action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    menu.addItem(.separator())
    _ = add("쓰다듬기", #selector(MenuTarget.pet))
    _ = add("재우기", #selector(MenuTarget.sleep))

    // 펫 바꾸기: 기본 샤네루 + 목록의 펫들. 지금 펫이 아닌 펫은 지울 수 있어요.
    let lib = libraryEntries()
    let petMenu = NSMenu()
    let names = displayNames(lib)
    let choices = [("", "꽃개 샤네루")] + lib.map { ($0.id, names[$0.id] ?? $0.name) }
    for (id, name) in choices {
        let i = add(name, #selector(MenuTarget.selectPet(_:)), to: petMenu)
        i.representedObject = id
        i.state = (p.id ?? (p.builtin ? "" : "?")) == id ? .on : .off
    }
    let removable = lib.filter { $0.id != p.id }
    if !removable.isEmpty {
        petMenu.addItem(.separator())
        let removeMenu = NSMenu()
        for e in removable {
            let i = add(names[e.id] ?? e.name, #selector(MenuTarget.removePet(_:)), to: removeMenu)
            i.representedObject = e.id
        }
        let removeRoot = NSMenuItem(title: "목록에서 지우기", action: nil, keyEquivalent: "")
        removeRoot.submenu = removeMenu
        petMenu.addItem(removeRoot)
    }
    let petRoot = NSMenuItem(title: "펫 바꾸기", action: nil, keyEquivalent: "")
    petRoot.submenu = petMenu
    menu.addItem(petRoot)

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
let ctl = Controller(pet: findPet())
let server = Server(path: sockPath) { line, fd in
    if line == "version" {
        // VS Code 확장이 버전을 물어보면 답해요. 예전 버전이면 확장이 새 버전으로 바꿔 띄워요.
        let reply = "version \(helperVersion) \(standalone ? "app" : "ext")\n"
        _ = reply.withCString { write(fd, $0, strlen($0)) }
    } else {
        ctl.handle(line)
    }
}
let appDelegate = AppDelegate(ctl: ctl)
app.delegate = appDelegate
if standalone {
    setupMenuBar(ctl)
    DispatchQueue.main.async {
        if let w = loadWarning { alert("펫을 불러오지 못했어요", w + (ctl.current.builtin ? "\n대신 샤네루가 나왔어요." : "")) }
        offerMoveToApplications()
    }
}

let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
    ctl.tick()
    // VS Code가 띄운 경우에만, 연결된 창이 없으면 종료
    if !standalone, let t = server.emptySince, CACurrentMediaTime() - t > 5 { quit() }
}
RunLoop.main.add(timer, forMode: .common)
app.run()
