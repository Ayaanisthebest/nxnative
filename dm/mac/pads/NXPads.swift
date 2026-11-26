// NX Pads: the Mac companion of phones as controllers (dm/host/phonepad_mac.m, DM_PHONE_PADS). It reads the running game's dashboard feed (wss://127.0.0.1:<port>/mon, or ws:// if the game is serving plain http) and shows
// a QR code of the address phones open, and every player's live input: phones, controllers and the keyboard. It waits and reconnects on its own while no game is running.
// Built by build.sh into "NX Pads.app" (swiftc, no Xcode project). `NXPads --render-icon <dir.iconset>` writes its icon's PNGs (build.sh turns them into AppIcon.icns).
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

let playerColors: [Color] = [0xff5a5f, 0x3fa7ff, 0xffcf3f, 0x3ddc84, 0xc77dff, 0xff8c42, 0x2ee6d6, 0xff6fb5].map {
    Color(red: Double($0 >> 16 & 0xff) / 255, green: Double($0 >> 8 & 0xff) / 255, blue: Double($0 & 0xff) / 255)
}
func playerColor(_ p: Int) -> Color { p >= 1 ? playerColors[(p - 1) % playerColors.count] : .gray }

enum Btn: Int { case a = 0, b, x, y, ls, rs, l, r, zl, zr, plus, minus, left, up, right, down }

struct Source: Identifiable {
    let id: String
    var player: Int
    var buttons: UInt16
    var lx = 0.0, ly = 0.0, rx = 0.0, ry = 0.0
    var rtt = 0.0
    var hz = 0
    var kind: String
    var name: String
    func on(_ b: Btn) -> Bool { buttons >> b.rawValue & 1 == 1 }
    var kindOrder: Int { kind == "phone" ? 0 : kind == "pad" ? 1 : 2 }
}

final class LocalTrust: NSObject, URLSessionTaskDelegate {
    static let shared = LocalTrust()
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let host = challenge.protectionSpace.host
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           (host == "127.0.0.1" || host == "localhost"), let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// The socket is read as fast as it arrives, and only the newest state of each player is kept. Painting every message in order made a
// busy moment replay old stick moves while the game, which takes the newest state only, was already on the current one.
final class Latest: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var sources: [String: Source] = [:]
    private var url: String?
    private var dirty = false
    private var armed = false

    func reset(_ gen: Int) {
        lock.lock(); generation = gen; sources = [:]; url = nil; dirty = false; armed = false; lock.unlock()
    }
    func apply(_ s: String, gen: Int) {
        let f = s.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        lock.lock()
        defer { lock.unlock() }
        guard gen == generation else { return }
        switch f.first {
        case "a" where f.count >= 2: url = f[1]; dirty = true
        case "x" where f.count >= 2: sources[f[1]] = nil; dirty = true
        case "u" where f.count >= 11:
            let m = 32767.0
            let src = Source(id: f[10], player: Int(f[1]) ?? 0, buttons: UInt16(truncatingIfNeeded: UInt64(f[2]) ?? 0),
                             lx: (Double(f[3]) ?? 0) / m, ly: (Double(f[4]) ?? 0) / m, rx: (Double(f[5]) ?? 0) / m, ry: (Double(f[6]) ?? 0) / m,
                             rtt: Double(f[7]) ?? 0, hz: Int(f[8]) ?? 0, kind: f[9], name: f.count > 11 ? f[11...].joined(separator: " ") : f[10])
            sources[src.id] = src; dirty = true
        default: break
        }
    }
    func arm(_ fire: @escaping @Sendable () -> Void) {   // one paint queued; messages that arrive before it replace what it draws
        lock.lock()
        let go = dirty && !armed
        if go { armed = true }
        lock.unlock()
        guard go else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: fire)
    }
    func snapshot() -> (sources: [String: Source], url: String?) {
        lock.lock(); let s = sources, u = url; dirty = false; armed = false; lock.unlock(); return (s, u)
    }
}

@MainActor final class Feed: ObservableObject {
    @Published var url: String?
    @Published var connected = false
    @Published var sources: [String: Source] = [:]
    @Published var port: Int = UserDefaults.standard.object(forKey: "port") as? Int ?? 8765
    @Published var standIn = false   // the phones are on NX Pads' own server (nxpadlobby), not a game's
    private var lobby: Process?
    private var lobbyAt = Date.distantPast
    private var task: URLSessionWebSocketTask?
    private var keepalive: Timer?
    private var generation = 0
    private var secure = true
    nonisolated private let latest = Latest()
    private let sockets: URLSession = URLSession(configuration: .default, delegate: LocalTrust.shared, delegateQueue: nil)

    var sorted: [Source] { sources.values.sorted { ($0.player, $0.kindOrder, $0.name) < ($1.player, $1.kindOrder, $1.name) } }

    func setPort(_ p: Int) {
        guard p > 0, p < 65536, p != port else { return }
        port = p; UserDefaults.standard.set(p, forKey: "port"); lobby?.terminate(); lobby = nil; connect()
    }
    // With no game serving, NX Pads serves the phone page itself so phones connect before a game starts; a game that starts ends it and the phones move over
    private func startLobby() {
        if let l = lobby, l.isRunning { return }
        guard Date().timeIntervalSince(lobbyAt) > 3, let exe = Bundle.main.url(forAuxiliaryExecutable: "nxpadlobby") else { return }
        lobbyAt = Date()
        let p = Process()
        p.executableURL = exe
        var env = ProcessInfo.processInfo.environment
        env["DM_PHONE_PADS"] = String(port)
        p.environment = env
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil { lobby = p }
    }
    func connect() {
        generation += 1; let gen = generation
        latest.reset(gen)
        keepalive?.invalidate(); task?.cancel(with: .goingAway, reason: nil)
        let scheme = secure ? "wss" : "ws"
        let t = sockets.webSocketTask(with: URL(string: "\(scheme)://127.0.0.1:\(port)/mon")!)
        task = t; t.resume()
        receive(t, gen)
        keepalive = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in   // the host drops a dashboard silent for 1.5 s; a broken connection ends the receive loop
            t.send(.string("k")) { _ in }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in   // the host sends its address at once; a connection made while a server was starting can hang with no error
            guard let self, gen == self.generation, !self.connected else { return }
            self.fail(gen)
        }
    }
    nonisolated private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let s)):
                self.latest.apply(s, gen: gen)
                self.receive(t, gen)   // the next message is read now, not after the window redraws
                self.latest.arm {
                    Task { @MainActor in self.republish(gen) }
                }
            case .success: self.receive(t, gen)
            case .failure: Task { @MainActor in self.fail(gen) }
            }
        }
    }
    private func republish(_ gen: Int) {
        guard gen == generation else { return }
        let snap = latest.snapshot()
        connected = true
        standIn = lobby?.isRunning ?? false
        if let u = snap.url { url = u }
        sources = snap.sources
        latest.arm { [weak self] in Task { @MainActor in self?.republish(gen) } }
    }
    private func fail(_ gen: Int) {
        guard gen == generation else { return }
        generation += 1
        latest.reset(generation)
        keepalive?.invalidate(); task?.cancel()
        connected = false; standIn = false; url = nil; sources = [:]
        startLobby()
        let wait: Double = secure ? 0.2 : 1   // https first; a game still on http answers the plain socket
        secure.toggle()
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.connect() }
    }
}

func qrImage(_ text: String) -> NSImage? {
    let f = CIFilter.qrCodeGenerator()
    f.message = Data(text.utf8); f.correctionLevel = "M"
    guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
          let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: out.extent.width, height: out.extent.height))
}

// MARK: - Views

struct ContentView: View {
    @StateObject var feed = Feed()
    var body: some View {
        HStack(spacing: 0) {
            Sidebar(feed: feed).frame(width: 320)
            Divider()
            Dashboard(feed: feed)
        }
        .frame(minWidth: 980, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { feed.connect() }
    }
}

struct Sidebar: View {
    @ObservedObject var feed: Feed
    @State private var portText = ""
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "gamecontroller.fill").font(.title2).foregroundStyle(.tint)
                Text("NX Pads").font(.title2.weight(.bold))
                Spacer()
                StatusPill(on: feed.connected, standIn: feed.standIn)
            }
            if let url = feed.url {
                VStack(spacing: 12) {
                    if let img = qrImage(url) {
                        Image(nsImage: img).interpolation(.none).resizable().aspectRatio(1, contentMode: .fit)
                            .padding(14).background(.white, in: RoundedRectangle(cornerRadius: 18))
                    }
                    HStack {
                        Text(url).font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(1).minimumScaleFactor(0.7)
                        Spacer()
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string)
                            copied = true; DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        }
                    }
                    if feed.standIn {
                        Label("No game running. Phones can connect and try the pad now; they move to the game when it starts.", systemImage: "iphone.gen3")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if url.contains("localhost") {
                        Label("The Mac has no Wi-Fi or Ethernet address: phones cannot reach it.", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Step(n: 1, text: "Join the same Wi-Fi as this Mac.")
                    Step(n: 2, text: "Scan the code with the iPhone Camera.")
                    Step(n: 3, text: "Turn the phone sideways. Tap Pro / Kart / Smash at the top to switch layouts, your name to rename.")
                    Step(n: 4, text: "Share → Add to Home Screen for a full-screen pad.")
                }
            } else {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Waiting for the game").font(.headline)
                    Text("Open the game with phone controllers on: DM_PHONE_PADS=1 in its env.txt (~/Library/Application Support/nxnative/<title ID>/env.txt).")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 40)
            }
            Spacer()
            Text("Phones on a guest network, or on Wi-Fi with client isolation, cannot reach the Mac.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Port").foregroundStyle(.secondary)
                TextField("8765", text: $portText).textFieldStyle(.roundedBorder).frame(width: 80)
                    .onSubmit { if let p = Int(portText) { feed.setPort(p) } }
                Spacer()
            }
            .onAppear { portText = String(feed.port) }
        }
        .padding(20)
    }
}

struct Step: View {
    let n: Int; let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.caption.weight(.bold)).frame(width: 20, height: 20).background(.quaternary, in: Circle())
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StatusPill: View {
    let on: Bool
    var standIn = false
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(on ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(!on ? "No game" : standIn ? "Phones ready" : "Game connected").font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10).padding(.vertical, 5).background(.quaternary, in: Capsule())
    }
}

struct Dashboard: View {
    @ObservedObject var feed: Feed
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Players").font(.title2.weight(.bold))
                Text("\(Set(feed.sources.values.map(\.player)).count) of 8").foregroundStyle(.secondary)
                Spacer()
            }
            if feed.sources.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.2.wave.2").font(.system(size: 44)).foregroundStyle(.tertiary)
                    Text(feed.connected ? "No players yet" : "Not connected").font(.headline)
                    Text(feed.connected ? "Scan the code with a phone, press a controller button or a key in the game window." : "Players show up here once the game is running.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 16)], spacing: 16) {
                        ForEach(feed.sorted) { PlayerCard(s: $0) }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .padding(20)
    }
}

struct PlayerCard: View {
    let s: Source
    var color: Color { playerColor(s.player) }
    var icon: String { s.kind == "phone" ? "iphone.landscape" : s.kind == "pad" ? "gamecontroller" : "keyboard" }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("P\(s.player)").font(.headline.weight(.heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4).background(color, in: Capsule())
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(s.name).font(.headline).lineLimit(1)
                Spacer()
                if s.kind == "phone" { Latency(ms: s.rtt, hz: s.hz) }
                else { Text(s.kind == "pad" ? "controller" : "keyboard").font(.caption).foregroundStyle(.secondary) }
            }
            ControllerView(s: s, color: color).frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(color.opacity(s.buttons != 0 ? 0.9 : 0.25), lineWidth: s.buttons != 0 ? 2 : 1))
    }
}

struct Latency: View {
    let ms: Double; let hz: Int
    var tint: Color { ms < 25 ? .green : ms < 60 ? .yellow : .red }
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) { Circle().fill(tint).frame(width: 7, height: 7); Text(String(format: "%.0f ms", ms)).monospacedDigit() }
            Text("\(hz)/s").foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.caption.weight(.semibold))
    }
}

// A Pro Controller drawn from one source's state: pressed buttons fill with the player's colour
struct ControllerView: View {
    let s: Source; let color: Color
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 40).fill(Color.primary.opacity(0.04)).frame(width: 300, height: 150).position(x: 150, y: 92)
            Key("ZL", s.on(.zl), color, w: 52).position(x: 40, y: 12)
            Key("L", s.on(.l), color, w: 52).position(x: 98, y: 12)
            Key("R", s.on(.r), color, w: 52).position(x: 202, y: 12)
            Key("ZR", s.on(.zr), color, w: 52).position(x: 260, y: 12)
            StickView(x: s.lx, y: s.ly, pressed: s.on(.ls), color: color, size: 62).position(x: 56, y: 76)
            Key("−", s.on(.minus), color, w: 24, h: 24, round: true).position(x: 122, y: 58)
            Key("+", s.on(.plus), color, w: 24, h: 24, round: true).position(x: 178, y: 58)
            DPadView(s: s, color: color).position(x: 112, y: 128)
            StickView(x: s.rx, y: s.ry, pressed: s.on(.rs), color: color, size: 56).position(x: 190, y: 128)
            Key("X", s.on(.x), color, w: 28, h: 28, round: true).position(x: 250, y: 50)
            Key("Y", s.on(.y), color, w: 28, h: 28, round: true).position(x: 220, y: 78)
            Key("A", s.on(.a), color, w: 28, h: 28, round: true).position(x: 280, y: 78)
            Key("B", s.on(.b), color, w: 28, h: 28, round: true).position(x: 250, y: 106)
        }
        .frame(width: 300, height: 170)
    }
}

struct Key: View {
    let label: String; let on: Bool; let color: Color; var w: CGFloat = 34; var h: CGFloat = 20; var round = false
    init(_ label: String, _ on: Bool, _ color: Color, w: CGFloat = 34, h: CGFloat = 20, round: Bool = false) {
        self.label = label; self.on = on; self.color = color; self.w = w; self.h = h; self.round = round
    }
    var body: some View {
        RoundedRectangle(cornerRadius: round ? h / 2 : 6)
            .fill(on ? color : Color.primary.opacity(0.09))
            .overlay(Text(label).font(.system(size: 11, weight: .bold)).foregroundStyle(on ? Color.white : Color.secondary))
            .frame(width: w, height: h)
            .shadow(color: on ? color.opacity(0.6) : .clear, radius: 6)
    }
}

struct StickView: View {
    let x: Double; let y: Double; let pressed: Bool; let color: Color; let size: CGFloat
    var body: some View {
        let moved = abs(x) > 0.08 || abs(y) > 0.08
        ZStack {
            Circle().fill(Color.primary.opacity(0.07))
            Circle().strokeBorder(pressed ? color : Color.primary.opacity(0.15), lineWidth: pressed ? 3 : 1)
            Path { p in p.move(to: CGPoint(x: size / 2, y: size / 2)); p.addLine(to: CGPoint(x: size / 2 + x * size * 0.34, y: size / 2 - y * size * 0.34)) }
                .stroke(color.opacity(moved ? 0.6 : 0), lineWidth: 2)
            Circle().fill(moved || pressed ? color : Color.primary.opacity(0.35)).frame(width: size * 0.32, height: size * 0.32)
                .offset(x: x * size * 0.34, y: -y * size * 0.34)
        }
        .frame(width: size, height: size)
    }
}

struct DPadView: View {
    let s: Source; let color: Color
    var body: some View {
        ZStack {
            arm(.up).offset(y: -16); arm(.down).offset(y: 16); arm(.left).offset(x: -16); arm(.right).offset(x: 16)
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.09)).frame(width: 16, height: 16)
        }
        .frame(width: 52, height: 52)
    }
    func arm(_ b: Btn) -> some View { RoundedRectangle(cornerRadius: 4).fill(s.on(b) ? color : Color.primary.opacity(0.09)).frame(width: 16, height: 16) }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

@main
struct NXPadsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count { renderIcon(to: args[i + 1]); exit(0) }
    }
    var body: some Scene {
        Window("NX Pads", id: "main") { ContentView() }
            .defaultSize(width: 1120, height: 680)
            .windowResizability(.contentMinSize)
    }
}

func renderIcon(to dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
        let s = CGFloat(px)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let inset = s * 0.1, rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
        NSGradient(colors: [NSColor(red: 0.25, green: 0.65, blue: 1, alpha: 1), NSColor(red: 0.47, green: 0.33, blue: 0.95, alpha: 1)])?.draw(in: shape, angle: -60)
        let cfg = NSImage.SymbolConfiguration(pointSize: rect.width * 0.5, weight: .semibold).applying(.init(paletteColors: [.white]))
        if let sym = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let sz = sym.size
            sym.draw(in: NSRect(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2, width: sz.width, height: sz.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("icon_\(name).png"))
    }
}
