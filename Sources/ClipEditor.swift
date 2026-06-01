import SwiftUI
import AppKit
import AVKit
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import UniformTypeIdentifiers

// ---- helpers -------------------------------------------------------------

// A Finder-launched app gets a minimal PATH without Homebrew, so resolve ffmpeg/
// ffprobe to absolute paths at startup and use those everywhere.
var gFFmpeg = "ffmpeg"
var gFFprobe = "ffprobe"
var gWhisper = "whisper-cli"
var gWhisperModel = ""
var gGgmlBackends = ""   // dir of bundled ggml backend plugins (empty in dev → use Homebrew default)
func resolveTools() {
    // Prefer tools/model bundled inside the .app (self-contained, for distribution);
    // fall back to Homebrew/PATH + a dev model path (for local development builds).
    let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
    // ggml auto-discovers backend plugins in the executable's dir (Helpers); also
    // pass GGML_BACKEND_PATH explicitly as a belt-and-suspenders.
    if FileManager.default.fileExists(atPath: helpers.path + "/libggml-metal.so") {
        gGgmlBackends = helpers.path
    }
    func find(_ n: String) -> String {
        let bundled = helpers.appendingPathComponent(n).path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        for p in ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"] {
            if FileManager.default.isExecutableFile(atPath: p + n) { return p + n }
        }
        return n
    }
    gFFmpeg = find("ffmpeg"); gFFprobe = find("ffprobe"); gWhisper = find("whisper-cli")
    if let m = Bundle.main.url(forResource: "ggml-base.en", withExtension: "bin") {
        gWhisperModel = m.path
    } else {
        gWhisperModel = NSHomeDirectory() + "/.hermes/skills/media/ffmpeg/models/ggml-base.en.bin"
    }
}
var whisperAvailable: Bool {
    FileManager.default.isExecutableFile(atPath: gWhisper) && FileManager.default.fileExists(atPath: gWhisperModel)
}

// Run a tool directly via Process with an ARGUMENT ARRAY (no shell). This makes
// shell injection impossible — file names/paths are passed as literal argv entries,
// never parsed by a shell. stderr is merged into stdout (replaces "2>&1").
@discardableResult
func runTool(_ exe: String, _ args: [String], env: [String: String] = [:]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if !env.isEmpty {
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        p.environment = e
    }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe          // merge stderr → same pipe
    do { try p.run() } catch { return "" }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

// Split a plan() codec string ("-c:v libx264 -crf 18 …") into argv tokens.
func args(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }

func fittedRect(_ container: CGSize, _ sw: CGFloat, _ sh: CGFloat) -> CGRect {
    guard sw > 0, sh > 0, container.width > 0, container.height > 0 else { return .zero }
    let scale = min(container.width / sw, container.height / sh)
    let w = sw * scale, h = sh * scale
    return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
}

func mmss(_ t: Double) -> String {
    let s = Int(t.rounded()); return String(format: "%d:%02d", s / 60, s % 60)
}

func humanSize(_ bytes: Double) -> String {
    if bytes >= 1_048_576 { return String(format: "%.1f MB", bytes / 1_048_576) }
    return String(format: "%.0f KB", bytes / 1024)
}

func fileBytes(_ path: String) -> Double {
    let a = try? FileManager.default.attributesOfItem(atPath: path)
    return Double((a?[.size] as? Int) ?? 0)
}

// Single source of truth for encode settings, shared by export AND the estimator
// so the estimate reflects exactly what export will do.
// format: "MP4" | "GIF" | "WEBM".  quality: "Fidelity" | "Balanced" | "Optimized".
// Returns the -vf filtergraph and the trailing codec args.
func plan(_ format: String, _ quality: String, _ crop: String, _ fps: Int?) -> (vf: String, codec: String) {
    let rate = (fps != nil) ? " -r \(fps!)" : ""
    switch format {
    case "GIF":
        let gfps: Int, maxw: Int, pal: String, use: String
        switch quality {
        case "Fidelity":  gfps = 20; maxw = 800; pal = "palettegen=stats_mode=full"; use = "paletteuse=dither=sierra2_4a"
        case "Optimized": gfps = 12; maxw = 480; pal = "palettegen=max_colors=128:stats_mode=diff"; use = "paletteuse=dither=bayer:bayer_scale=2"
        default:          gfps = 15; maxw = 640; pal = "palettegen=stats_mode=diff"; use = "paletteuse=dither=bayer"
        }
        let vf = "\(crop),fps=\(fps ?? gfps),scale='min(\(maxw),iw)':-1:flags=lanczos," +
                 "split[a][b];[a]\(pal)[p];[b][p]\(use)"
        return (vf, "")
    case "WEBM":
        var vf = crop; var crf = 32; var ab = 128; var extra = "-row-mt 1"
        switch quality {
        case "Fidelity":  crf = 24; ab = 160
        case "Optimized": crf = 40; ab = 96; extra = "-row-mt 1 -deadline good -cpu-used 3"; vf = "\(crop),scale=-2:'min(720,ih)'"
        default: break
        }
        return (vf, "-c:v libvpx-vp9 -crf \(crf) -b:v 0 \(extra) -pix_fmt yuv420p\(rate) -c:a libopus -b:a \(ab)k")
    default: // MP4
        var vf = crop; var crf = 22; var preset = "medium"; var ab = 128
        switch quality {
        case "Fidelity":  crf = 16; preset = "slow"; ab = 192
        case "Optimized": crf = 30; preset = "slower"; ab = 96; vf = "\(crop),scale=-2:'min(720,ih)'"
        default: break
        }
        return (vf, "-c:v libx264 -crf \(crf) -preset \(preset) -pix_fmt yuv420p\(rate) -c:a aac -b:a \(ab)k -movflags +faststart")
    }
}

// ---- screen recorder (in-process ScreenCaptureKit) ------------------------

@available(macOS 15, *)
final class ScreenRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private(set) var outputURL: URL?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    var onError: ((String) -> Void)?

    // displayID/sourceRect/pixel size are computed by the caller (region mapping).
    func start(displayID: CGDirectDisplayID?, sourceRect: CGRect?,
               pixelW: Int, pixelH: Int, micOn: Bool, sysAudio: Bool, cursor: Bool) async throws {
        let content = try await SCShareableContent.current
        guard let display = (displayID != nil
                ? content.displays.first { $0.displayID == displayID }
                : content.displays.first) else {
            throw NSError(domain: "MBClip", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No capturable display found."])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = max(2, pixelW - pixelW % 2)
        config.height = max(2, pixelH - pixelH % 2)
        if let r = sourceRect { config.sourceRect = r }
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = cursor
        config.captureMicrophone = micOn
        config.capturesAudio = sysAudio        // system/screen audio

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mbrec_\(Int(Date().timeIntervalSince1970)).mov")
        outputURL = url
        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = url
        rc.outputFileType = .mov
        rc.videoCodecType = .h264

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        let rec = SCRecordingOutput(configuration: rc, delegate: self)
        try s.addRecordingOutput(rec)         // must precede startCapture()
        try await s.startCapture()
        stream = s; recordingOutput = rec
    }

    func stop() async {
        guard let s = stream else { return }
        // Wait for the file to finish writing, with a timeout so we never hang.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            finishContinuation = cont
            Task {
                try? await s.stopCapture()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let c = finishContinuation { finishContinuation = nil; c.resume() }
            }
        }
        stream = nil; recordingOutput = nil
    }

    // SCRecordingOutputDelegate
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        onError?("Recording failed: \(error.localizedDescription)")
        if let c = finishContinuation { finishContinuation = nil; c.resume() }
    }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        if let c = finishContinuation { finishContinuation = nil; c.resume() }
    }

    // SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("Capture stopped: \(error.localizedDescription)")
        if let c = finishContinuation { finishContinuation = nil; c.resume() }
    }
}

// ---- state ---------------------------------------------------------------

final class EditorState: ObservableObject {
    @Published var inputURL: URL?
    @Published var isGif = false
    @Published var srcW: CGFloat = 0
    @Published var srcH: CGFloat = 0
    @Published var duration: Double = 0
    @Published var current: Double = 0
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    // crop in SOURCE pixels
    @Published var cropX: CGFloat = 0
    @Published var cropY: CGFloat = 0
    @Published var cropW: CGFloat = 0
    @Published var cropH: CGFloat = 0
    @Published var playing = false
    @Published var loading = false
    @Published var exporting = false
    @Published var estimating = false
    @Published var status = "Drop a .mp4 or .gif to begin."
    @Published var statusKind = "info"   // info | work | ok | err
    @Published var outFormat = "Same as input"
    @Published var quality = "Balanced"   // Fidelity | Balanced | Optimized
    @Published var outName = ""
    @Published var scale = "1.0"           // 0–1 output scale (0.5 = half dimensions)
    @Published var srcFps: Double = 0      // source frame rate
    @Published var fpsOn = false           // override fps?
    @Published var fpsText = ""            // target fps when overriding
    // captions / transcription (whisper.cpp)
    @Published var capBurn = false         // burn subtitles into the video
    @Published var capSrt = false          // save sidecar .srt
    @Published var capTxt = false          // save plain transcript .txt
    @Published var queue: [URL] = []       // batch queue
    @Published var queueIndex = 0
    @Published var exportFolder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")

    // screen recording
    @Published var recording = false
    @Published var recElapsed: Double = 0
    @Published var screens: [(id: CGDirectDisplayID, name: String)] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var micOn = false
    @Published var sysAudioOn = false
    @Published var cursorOn = true
    @Published var regionOn = false
    var recorder: AnyObject?               // ScreenRecorder (type-erased to avoid @available leak)
    var regionSelector: RegionSelector?
    var screenLabelWindows: [NSWindow] = []   // "identify" number overlays
    var recTimer: Timer?
    var recStart: Date?

    func setStatus(_ msg: String, _ kind: String = "info") { status = msg; statusKind = kind }

    let player = AVPlayer()
    var previewURL: URL?
    var timeObserver: Any?

    func resetCropFull() { cropX = 0; cropY = 0; cropW = srcW; cropH = srcH }

    func attachObserver() {
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        let t = CMTime(seconds: 0.03, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: t, queue: .main) { [weak self] tm in
            guard let self = self else { return }
            self.current = tm.seconds
            // Loop within the trim region while playing.
            if self.playing, self.trimEnd > self.trimStart, tm.seconds >= self.trimEnd - 0.02 {
                self.seek(self.trimStart)
            }
        }
    }

    func seek(_ s: Double) {
        let cm = CMTime(seconds: max(0, s), preferredTimescale: 600)
        player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        current = s
    }

    func togglePlay() {
        if playing { player.pause(); playing = false }
        else {
            if current >= trimEnd - 0.02 || current < trimStart { seek(trimStart) }
            player.play(); playing = true
        }
    }
}

// ---- AVPlayer NSView -----------------------------------------------------

final class PlayerNSView: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer = AVPlayerLayer() }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerNSView {
        let v = PlayerNSView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.backgroundColor = NSColor.black.cgColor
        return v
    }
    func updateNSView(_ v: PlayerNSView, context: Context) { v.playerLayer.player = player }
}

// ---- screen region selector ----------------------------------------------

final class KeyableWindow: NSWindow { override var canBecomeKey: Bool { true } }

// Transparent, borderless window: drag the body to move (across displays),
// drag the bottom-right handle to resize. Shows W×H. Excluded from capture.
final class RegionView: NSView {
    private enum Mode { case move, bl, br, tl, tr }   // corner being resized, or move
    private let grab: CGFloat = 22                     // corner hit/draw size
    private var mode: Mode = .move
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero

    override func draw(_ dirty: NSRect) {
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)); border.lineWidth = 2
        NSColor.controlAccentColor.setStroke(); border.stroke()
        // grabbers in all four corners
        NSColor.controlAccentColor.setFill()
        let g = grab - 4
        for c in [NSRect(x: 0, y: 0, width: g, height: g),                       // bottom-left
                  NSRect(x: bounds.maxX - g, y: 0, width: g, height: g),          // bottom-right
                  NSRect(x: 0, y: bounds.maxY - g, width: g, height: g),          // top-left
                  NSRect(x: bounds.maxX - g, y: bounds.maxY - g, width: g, height: g)] { // top-right
            NSBezierPath(roundedRect: c, xRadius: 3, yRadius: 3).fill()
        }
        let txt = "\(Int(frame.width)) × \(Int(frame.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white,
                                                     .font: NSFont.systemFont(ofSize: 12, weight: .semibold)]
        let sz = txt.size(withAttributes: attrs)
        let bg = NSRect(x: (bounds.width - sz.width)/2 - 6, y: (bounds.height - sz.height)/2 - 3,
                        width: sz.width + 12, height: sz.height + 6)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        txt.draw(at: NSPoint(x: (bounds.width - sz.width)/2, y: (bounds.height - sz.height)/2), withAttributes: attrs)
    }

    override func mouseDown(with e: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startFrame = window?.frame ?? .zero
        let p = convert(e.locationInWindow, from: nil)
        let left = p.x < grab, right = p.x > bounds.maxX - grab
        let bottom = p.y < grab, top = p.y > bounds.maxY - grab
        if      left && bottom  { mode = .bl }
        else if right && bottom { mode = .br }
        else if left && top     { mode = .tl }
        else if right && top    { mode = .tr }
        else                    { mode = .move }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let win = window else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - startMouse.x, dy = m.y - startMouse.y
        if mode == .move {
            win.setFrameOrigin(NSPoint(x: startFrame.minX + dx, y: startFrame.minY + dy)); return
        }
        let minW: CGFloat = 80, minH: CGFloat = 60
        var x = startFrame.minX, y = startFrame.minY, w = startFrame.width, h = startFrame.height
        switch mode {
        case .br: w = startFrame.width + dx; h = startFrame.height - dy; y = startFrame.minY + dy
        case .bl: w = startFrame.width - dx; h = startFrame.height - dy; x = startFrame.minX + dx; y = startFrame.minY + dy
        case .tr: w = startFrame.width + dx; h = startFrame.height + dy
        case .tl: w = startFrame.width - dx; h = startFrame.height + dy; x = startFrame.minX + dx
        case .move: break
        }
        // Clamp to minimums while keeping the opposite (anchored) corner fixed.
        if w < minW { if mode == .bl || mode == .tl { x = startFrame.maxX - minW }; w = minW }
        if h < minH { if mode == .bl || mode == .br { y = startFrame.maxY - minH }; h = minH }
        win.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        needsDisplay = true
    }
}

final class RegionSelector {
    let window: NSPanel
    init() {
        let f = NSRect(x: 320, y: 320, width: 640, height: 360)
        // Non-activating panel so it can float over other apps' fullscreen Spaces
        // yet still receive drag/resize clicks without stealing focus.
        window = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.level = .screenSaver
        window.hidesOnDeactivate = false
        window.sharingType = .none                                   // invisible to screen capture
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        let v = RegionView(frame: NSRect(origin: .zero, size: f.size))
        v.autoresizingMask = [.width, .height]
        window.contentView = v
    }
    func show() { window.orderFrontRegardless() }   // appear over fullscreen without activating
    func hide() { window.orderOut(nil) }

    // Map the window to (displayID, sourceRect in display-local TOP-LEFT points, output pixels).
    func captureInfo() -> (displayID: CGDirectDisplayID, rect: CGRect, pxW: Int, pxH: Int)? {
        let wf = window.frame
        // Choose the screen with the largest overlap with the window.
        let scr = NSScreen.screens.max { a, b in
            a.frame.intersection(wf).area < b.frame.intersection(wf).area
        } ?? NSScreen.main
        guard let screen = scr,
              let num = screen.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? NSNumber
        else { return nil }
        let displayID = CGDirectDisplayID(num.uint32Value)
        let scale = screen.backingScaleFactor
        let sf = screen.frame
        // Clamp window to the screen, then convert to display-local top-left points.
        let clamped = wf.intersection(sf)
        let useRect = clamped.isNull ? wf : clamped
        let localX = useRect.minX - sf.minX
        let localTopY = sf.height - ((useRect.minY - sf.minY) + useRect.height)   // y-flip
        let rect = CGRect(x: max(0, localX), y: max(0, localTopY),
                          width: useRect.width, height: useRect.height)
        let pxW = Int((rect.width * scale).rounded())
        let pxH = Int((rect.height * scale).rounded())
        return (displayID, rect, pxW, pxH)
    }
}

extension NSRect { var area: CGFloat { isNull ? 0 : width * height } }

// Big number shown centered on a physical display to identify it.
final class NumberOverlayView: NSView {
    var number = 0
    override func draw(_ r: NSRect) {
        let box = bounds.insetBy(dx: 8, dy: 8)
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: box, xRadius: 30, yRadius: 30).fill()
        let stroke = NSBezierPath(roundedRect: box, xRadius: 30, yRadius: 30); stroke.lineWidth = 6
        NSColor.controlAccentColor.setStroke(); stroke.stroke()
        let txt = "\(number)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white,
                                                     .font: NSFont.systemFont(ofSize: 130, weight: .bold)]
        let sz = txt.size(withAttributes: attrs)
        txt.draw(at: NSPoint(x: (bounds.width - sz.width)/2, y: (bounds.height - sz.height)/2), withAttributes: attrs)
    }
}

// ---- crop overlay --------------------------------------------------------

struct CropOverlay: View {
    @EnvironmentObject var s: EditorState
    let container: CGSize

    @State private var snap: CGRect? = nil   // crop (src px) at drag start

    var body: some View {
        let fit = fittedRect(container, s.srcW, s.srcH)
        let scale = s.srcW > 0 ? fit.width / s.srcW : 1
        let r = CGRect(x: fit.minX + s.cropX * scale,
                       y: fit.minY + s.cropY * scale,
                       width: s.cropW * scale,
                       height: s.cropH * scale)
        ZStack(alignment: .topLeading) {
            // dim outside crop
            Path { p in
                p.addRect(CGRect(origin: .zero, size: container))
                p.addRect(r)
            }.fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))

            Rectangle().path(in: r).stroke(Color.yellow, lineWidth: 2)

            // move handle (whole body)
            Color.clear.frame(width: r.width, height: r.height)
                .contentShape(Rectangle())
                .offset(x: r.minX, y: r.minY)
                .gesture(DragGesture().onChanged { g in
                    if snap == nil { snap = CGRect(x: s.cropX, y: s.cropY, width: s.cropW, height: s.cropH) }
                    guard let b = snap else { return }
                    s.cropX = clamp(b.minX + g.translation.width / scale, 0, s.srcW - b.width)
                    s.cropY = clamp(b.minY + g.translation.height / scale, 0, s.srcH - b.height)
                }.onEnded { _ in snap = nil })

            corner(r, .topLeading, scale)
            corner(r, .topTrailing, scale)
            corner(r, .bottomLeading, scale)
            corner(r, .bottomTrailing, scale)
        }
        .frame(width: container.width, height: container.height)
    }

    enum Corner { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    func corner(_ r: CGRect, _ c: Corner, _ scale: CGFloat) -> some View {
        let pt: CGPoint
        switch c {
        case .topLeading: pt = CGPoint(x: r.minX, y: r.minY)
        case .topTrailing: pt = CGPoint(x: r.maxX, y: r.minY)
        case .bottomLeading: pt = CGPoint(x: r.minX, y: r.maxY)
        case .bottomTrailing: pt = CGPoint(x: r.maxX, y: r.maxY)
        }
        return Circle().fill(Color.yellow).frame(width: 14, height: 14)
            .offset(x: pt.x - 7, y: pt.y - 7)
            .gesture(DragGesture().onChanged { g in
                if snap == nil { snap = CGRect(x: s.cropX, y: s.cropY, width: s.cropW, height: s.cropH) }
                guard let b = snap else { return }
                let dx = g.translation.width / scale, dy = g.translation.height / scale
                var x = b.minX, y = b.minY, w = b.width, h = b.height
                switch c {
                case .topLeading:     x = b.minX + dx; y = b.minY + dy; w = b.width - dx; h = b.height - dy
                case .topTrailing:    y = b.minY + dy; w = b.width + dx; h = b.height - dy
                case .bottomLeading:  x = b.minX + dx; w = b.width - dx; h = b.height + dy
                case .bottomTrailing: w = b.width + dx; h = b.height + dy
                }
                if w < 16 { w = 16; x = min(x, b.maxX - 16) }
                if h < 16 { h = 16; y = min(y, b.maxY - 16) }
                x = clamp(x, 0, s.srcW - 16); y = clamp(y, 0, s.srcH - 16)
                w = clamp(w, 16, s.srcW - x); h = clamp(h, 16, s.srcH - y)
                s.cropX = x; s.cropY = y; s.cropW = w; s.cropH = h
            }.onEnded { _ in snap = nil })
    }
}

func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), max(lo, hi)) }

// ---- timeline ------------------------------------------------------------

struct Timeline: View {
    @EnvironmentObject var s: EditorState

    var body: some View {
        GeometryReader { geo in
            // Inset the track by half a handle-width on each side so the handles are
            // FULLY inside the interactive frame even at the extreme start/end.
            let inset = hitW / 2
            let W = max(1, geo.size.width - inset * 2)        // inner (track) width
            let dur = max(s.duration, 0.001)
            let xStart = inset + CGFloat(s.trimStart / dur) * W
            let xEnd = inset + CGFloat(s.trimEnd / dur) * W
            let xCur = inset + CGFloat(s.current / dur) * W
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.25))
                    .padding(.horizontal, inset)
                // selected region
                Rectangle().fill(Color.accentColor.opacity(0.30))
                    .frame(width: max(0, xEnd - xStart)).offset(x: xStart)
                // playhead
                Rectangle().fill(Color.white).frame(width: 2).offset(x: xCur - 1)
                // trim handles — wide grab area, yellow, with direction arrows.
                handle(.right)                                  // start: ▶ points into the clip
                    .offset(x: xStart - hitW / 2)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("tl")).onChanged { g in
                        let t = clamp(Double((g.location.x - inset) / W) * dur, 0, s.trimEnd - 0.1)
                        s.trimStart = t; s.seek(t)
                    })
                handle(.left)                                   // end: ◀ points into the clip
                    .offset(x: xEnd - hitW / 2)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("tl")).onChanged { g in
                        let t = clamp(Double((g.location.x - inset) / W) * dur, s.trimStart + 0.1, s.duration)
                        s.trimEnd = t; s.seek(t)
                    })
            }
            .frame(height: 40)
            .coordinateSpace(name: "tl")
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("tl")).onChanged { g in
                // scrub playhead when dragging on the bar background (away from handles)
                let t = clamp(Double((g.location.x - inset) / W) * dur, 0, s.duration)
                if abs(g.location.x - xStart) > hitW / 2 && abs(g.location.x - xEnd) > hitW / 2 {
                    s.seek(t)
                }
            })
        }
        .frame(height: 40)
    }

    enum Dir { case left, right }
    private var hitW: CGFloat { 30 }   // generous grab width (no dead spot)

    func handle(_ dir: Dir) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(Color.yellow)
                .frame(width: 16, height: 40)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.55), lineWidth: 1))
            Image(systemName: dir == .right ? "arrowtriangle.right.fill" : "arrowtriangle.left.fill")
                .font(.system(size: 10, weight: .black)).foregroundColor(.black)
        }
        .frame(width: hitW, height: 40)        // wide, fully-hittable grab zone
        .contentShape(Rectangle())
    }
}

// ---- main view -----------------------------------------------------------

struct ContentView: View {
    @EnvironmentObject var s: EditorState
    @State private var dropTargeted = false
    @State private var screenMenuOpen = false

    var body: some View {
        VStack(spacing: 10) {
            // recording controls
            if #available(macOS 15, *) {
                HStack(spacing: 10) {
                    if s.recording {
                        Button(action: { stopRecording() }) {
                            Label("Stop  \(mmss(s.recElapsed))", systemImage: "stop.fill")
                        }.tint(.red).buttonStyle(.borderedProminent)
                        Text("● REC").font(.system(size: 11, weight: .bold)).foregroundColor(.red)
                    } else {
                        Button(action: { startRecording() }) {
                            Label("Record Screen", systemImage: "record.circle")
                        }.tint(.red)
                        Toggle("Region", isOn: $s.regionOn)
                            .toggleStyle(.button)
                            .onChange(of: s.regionOn) { on in toggleRegion(on) }
                        if !s.regionOn && !s.screens.isEmpty {
                            Button(action: { screenMenuOpen.toggle() }) {
                                HStack(spacing: 4) {
                                    Text("Screen \(currentScreenIndex)")
                                    Image(systemName: "chevron.down").font(.system(size: 9))
                                }
                            }
                            .popover(isPresented: $screenMenuOpen, arrowEdge: .bottom) {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(s.screens.enumerated()), id: \.element.id) { i, scr in
                                        Button("Screen \(i)") { s.selectedDisplayID = scr.id; screenMenuOpen = false }
                                            .buttonStyle(.plain).padding(.vertical, 2).padding(.horizontal, 6)
                                    }
                                }.padding(8)
                            }
                            // Reliable open/close signal → numbers appear every time, vanish on close.
                            .onChange(of: screenMenuOpen) { open in
                                if open { showScreenNumbers() } else { hideScreenNumbers() }
                            }
                        }
                        Toggle("Mic", isOn: $s.micOn).toggleStyle(.checkbox)
                        Toggle("Screen audio", isOn: $s.sysAudioOn).toggleStyle(.checkbox)
                        Toggle("Cursor", isOn: $s.cursorOn).toggleStyle(.checkbox)
                    }
                    Spacer()
                }
            }

            // preview + crop
            GeometryReader { geo in
                ZStack {
                    Color.black
                    PlayerView(player: s.player)
                    if s.srcW > 0 { CropOverlay(container: geo.size).environmentObject(s) }
                    if s.inputURL == nil {
                        VStack(spacing: 8) {
                            Image(systemName: "film").font(.system(size: 40)).foregroundColor(.white.opacity(0.4))
                            Text("Drop a .mp4 or .gif here").foregroundColor(.white.opacity(0.5))
                        }
                    }
                    if s.loading {
                        Text("Loading preview…").padding(8).background(.black.opacity(0.6))
                            .foregroundColor(.white).cornerRadius(6)
                    }
                }
                .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
                    loadDropped(providers); return true
                }
                .border(dropTargeted ? Color.accentColor : Color.clear, width: 3)
            }
            .frame(minHeight: 280)

            if s.queue.count > 1 {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill").foregroundColor(.accentColor)
                    Text("Clip \(s.queueIndex + 1) of \(s.queue.count): \(s.inputURL?.lastPathComponent ?? "")")
                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer()
                    Button("◀︎ Prev") { navQueue(-1) }.disabled(s.queueIndex == 0 || s.exporting)
                    Button("Next ▶︎") { navQueue(1) }.disabled(s.queueIndex >= s.queue.count - 1 || s.exporting)
                    Button("Remove") { removeCurrent() }.disabled(s.exporting)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
            }

            // transport
            HStack(spacing: 12) {
                Button(action: { s.togglePlay() }) {
                    Image(systemName: s.playing ? "pause.fill" : "play.fill")
                }.disabled(s.inputURL == nil)
                Text("\(mmss(s.current)) / \(mmss(s.duration))").font(.system(size: 11, design: .monospaced))
                Spacer()
                if s.srcW > 0 {
                    Text("Crop \(Int(s.cropW))×\(Int(s.cropH)) → out \(outW)×\(outH)")
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                    Button("Reset crop") { s.resetCropFull() }.font(.system(size: 11))
                }
            }

            Timeline().environmentObject(s)

            HStack {
                Text("Trim  \(mmss(s.trimStart)) → \(mmss(s.trimEnd))  (\(mmss(s.trimEnd - s.trimStart)))")
                    .font(.system(size: 11, design: .monospaced))
                Spacer()
                Picker("", selection: $s.quality) {
                    Text("High fidelity").tag("Fidelity")
                    Text("Balanced").tag("Balanced")
                    Text("High optimization").tag("Optimized")
                }.pickerStyle(.segmented).frame(width: 320).labelsHidden().disabled(s.exporting)
            }
            Text(qualityHint).font(.system(size: 10)).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)

            HStack(spacing: 8) {
                Text("Captions").font(.system(size: 11)).foregroundColor(.secondary)
                Toggle("Embed subs", isOn: $s.capBurn).toggleStyle(.checkbox).disabled(s.exporting)
                    .help("Embed a toggleable subtitle track in the MP4 (mov_text). MP4 only.")
                Toggle(".srt", isOn: $s.capSrt).toggleStyle(.checkbox).disabled(s.exporting)
                    .help("Save a separate .srt subtitle file next to the export.")
                Toggle("Transcript", isOn: $s.capTxt).toggleStyle(.checkbox).disabled(s.exporting)
                    .help("Save the spoken text as a .txt file.")
                if (s.capBurn || s.capSrt || s.capTxt) && !whisperAvailable {
                    Text("⚠︎ whisper not found").font(.system(size: 10)).foregroundColor(.orange)
                } else if s.capBurn || s.capSrt || s.capTxt {
                    Text("(adds a transcription pass)").font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Text("Name").font(.system(size: 11)).foregroundColor(.secondary)
                TextField("output name", text: $s.outName)
                    .textFieldStyle(.roundedBorder).frame(width: 170).disabled(s.exporting)
                Text("Scale").font(.system(size: 11)).foregroundColor(.secondary)
                TextField("1.0", text: $s.scale)
                    .textFieldStyle(.roundedBorder).frame(width: 48).disabled(s.exporting)
                    .help("Output scale 0–1 (e.g. 0.5 = half size)")
                Toggle("FPS", isOn: $s.fpsOn).toggleStyle(.checkbox).disabled(s.exporting)
                    .help("Override frame rate. Off = keep source fps.")
                TextField(s.srcFps > 0 ? String(Int(s.srcFps.rounded())) : "fps", text: $s.fpsText)
                    .textFieldStyle(.roundedBorder).frame(width: 44)
                    .disabled(!s.fpsOn || s.exporting)
                Picker("", selection: $s.outFormat) {
                    Text("Same as input").tag("Same as input")
                    Text("MP4").tag("MP4")
                    Text("GIF").tag("GIF")
                    Text("Web (webm + gif)").tag("Web")
                }.frame(width: 170).labelsHidden().disabled(s.exporting)
                Spacer()
                Button("Estimate size") { estimateSize() }
                    .disabled(s.inputURL == nil || s.exporting || s.estimating)
                Button(action: { chooseExportFolder() }) {
                    Label(s.exportFolder.lastPathComponent, systemImage: "folder")
                }.disabled(s.exporting).help("Set export location (currently: \(s.exportFolder.path))")
                Button(s.exporting ? "Exporting…" : (s.queue.count > 1 ? "Export & Next" : "Export")) { export() }
                    .buttonStyle(.borderedProminent)
                    .disabled(s.inputURL == nil || s.exporting || s.estimating)
            }

            statusBar
        }
        .padding(14)
        .frame(minWidth: 780, minHeight: 640)
        .onAppear { enumerateScreens() }
    }

    // Output dimensions after crop + scale (even, matching the crop filter).
    var outW: Int { let v = Int((s.cropW * CGFloat(scaleFactor())).rounded()); return max(2, v - v % 2) }
    var outH: Int { let v = Int((s.cropH * CGFloat(scaleFactor())).rounded()); return max(2, v - v % 2) }

    var qualityHint: String {
        switch s.quality {
        case "Fidelity":  return "Retain detail — high quality, larger files, no downscaling."
        case "Optimized": return "Smallest reasonable — stronger compression, caps to 720p."
        default:          return "Balanced — slight compression at near-original quality."
        }
    }

    // Bottom feedback bar: spinner while working, colored result otherwise.
    var statusBar: some View {
        HStack(spacing: 8) {
            switch s.statusKind {
            case "work":
                ProgressView().controlSize(.small).scaleEffect(0.8)
            case "ok":
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            case "err":
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
            default:
                Image(systemName: "info.circle").foregroundColor(.secondary)
            }
            Text(s.status)
                .font(.system(size: 11))
                .foregroundColor(s.statusKind == "ok" ? .green : (s.statusKind == "err" ? .red : .secondary))
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.12)))
    }

    // MARK: queue

    static let acceptedExts: Set<String> = ["mp4","gif","mov","mkv","m4v","webm","avi","mpg","mpeg","ts","wmv","3gp","m2ts"]

    func videoFiles(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { Self.acceptedExts.contains($0.pathExtension.lowercased()) }
    }

    // Collect every dropped file/folder into the queue, then load the first.
    func loadDropped(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = DispatchQueue(label: "drop.collect")
        var urls: [URL] = []
        for p in providers {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var u: URL?
                if let d = item as? Data { u = URL(dataRepresentation: d, relativeTo: nil) }
                else if let x = item as? URL { u = x }
                if let u = u { lock.sync { urls.append(u) } }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            var files: [URL] = []
            for u in urls { if u.hasDirectoryPath { files += self.videoFiles(in: u) } else { files.append(u) } }
            files = files.filter { Self.acceptedExts.contains($0.pathExtension.lowercased()) }
                         .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            guard !files.isEmpty else { return }
            s.queue = files; s.queueIndex = 0
            load(files[0])
        }
    }

    func navQueue(_ d: Int) {
        let i = s.queueIndex + d
        guard i >= 0 && i < s.queue.count else { return }
        s.queueIndex = i; load(s.queue[i])
    }

    // Remove just the clip currently being previewed; load a neighbor (or clear if none left).
    func removeCurrent() {
        guard !s.queue.isEmpty else { return }
        s.queue.remove(at: min(s.queueIndex, s.queue.count - 1))
        if s.queue.isEmpty {
            s.inputURL = nil; s.srcW = 0; s.player.replaceCurrentItem(with: nil)
            s.setStatus("Queue empty — drop or record a clip.", "info")
        } else {
            if s.queueIndex >= s.queue.count { s.queueIndex = s.queue.count - 1 }
            load(s.queue[s.queueIndex])
        }
    }

    // MARK: screen recording

    // Enumerate capturable displays (also warms the Screen Recording permission).
    func enumerateScreens() {
        guard #available(macOS 15, *) else { return }
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.current
                s.screens = content.displays.enumerated().map { (i, d) in (id: d.displayID, name: "Screen \(i)") }
                if s.selectedDisplayID == nil { s.selectedDisplayID = s.screens.first?.id }
            } catch {
                s.screens = []   // permission not granted yet; Record will prompt
            }
        }
    }

    var currentScreenIndex: Int { s.screens.firstIndex { $0.id == s.selectedDisplayID } ?? 0 }

    // Flash a big number on each physical display, matching the dropdown order.
    func showScreenNumbers() {
        hideScreenNumbers()
        for (i, scr) in s.screens.enumerated() {
            guard let nss = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? NSNumber)?.uint32Value == scr.id
            }) else { continue }
            let size: CGFloat = 200
            let rect = NSRect(x: nss.frame.midX - size/2, y: nss.frame.midY - size/2, width: size, height: size)
            // A non-activating floating panel can draw over other apps' fullscreen Spaces.
            let win = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            win.isFloatingPanel = true
            win.isOpaque = false; win.backgroundColor = .clear; win.hasShadow = false
            win.level = .screenSaver; win.ignoresMouseEvents = true; win.sharingType = .none
            win.hidesOnDeactivate = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            win.isReleasedWhenClosed = false
            let v = NumberOverlayView(frame: NSRect(origin: .zero, size: rect.size)); v.number = i
            win.contentView = v
            win.orderFrontRegardless()
            s.screenLabelWindows.append(win)
        }
    }
    func hideScreenNumbers() {
        for w in s.screenLabelWindows { w.orderOut(nil) }
        s.screenLabelWindows.removeAll()
    }

    func toggleRegion(_ on: Bool) {
        if on {
            if s.regionSelector == nil { s.regionSelector = RegionSelector() }
            s.regionSelector?.show()
        } else {
            s.regionSelector?.hide()
        }
    }

    func startRecording() {
        guard #available(macOS 15, *) else {
            s.setStatus("Screen recording requires macOS 15 or later.", "err"); return
        }
        // Resolve display + region in pixels.
        var displayID = s.selectedDisplayID
        var sourceRect: CGRect? = nil
        var pxW = 0, pxH = 0
        if s.regionOn, let sel = s.regionSelector, sel.window.isVisible, let info = sel.captureInfo() {
            displayID = info.displayID; sourceRect = info.rect; pxW = info.pxW; pxH = info.pxH
        }

        let rec = ScreenRecorder()
        rec.onError = { msg in DispatchQueue.main.async { s.setStatus(msg, "err"); self.endRecordingUI() } }
        s.recorder = rec
        s.setStatus("Starting recording…", "work")
        Task { @MainActor in
            do {
                // Full-screen: derive pixel size from the chosen display.
                if sourceRect == nil {
                    let content = try await SCShareableContent.current
                    let d = (displayID != nil ? content.displays.first { $0.displayID == displayID } : content.displays.first)
                    guard let disp = d else { throw NSError(domain: "MBClip", code: 2, userInfo: [NSLocalizedDescriptionKey: "No display."]) }
                    displayID = disp.displayID
                    let scale = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? NSNumber)?.uint32Value == disp.displayID }?.backingScaleFactor ?? 2
                    pxW = Int(CGFloat(disp.width) * scale); pxH = Int(CGFloat(disp.height) * scale)
                }
                try await rec.start(displayID: displayID, sourceRect: sourceRect, pixelW: pxW, pixelH: pxH, micOn: s.micOn, sysAudio: s.sysAudioOn, cursor: s.cursorOn)
                s.recording = true
                s.recStart = Date(); s.recElapsed = 0
                s.recTimer?.invalidate()
                s.recTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    if let st = s.recStart { s.recElapsed = Date().timeIntervalSince(st) }
                }
                s.setStatus("● Recording\(s.regionOn ? " region" : "")\(s.micOn ? " + mic" : "")\(s.sysAudioOn ? " + audio" : "") — click Stop when done.", "work")
            } catch {
                s.recorder = nil
                s.setStatus("Couldn't start recording: \(error.localizedDescription). If this is the first time, enable SimpleClips in System Settings ▸ Privacy & Security ▸ Screen Recording, then relaunch.", "err")
            }
        }
    }

    func endRecordingUI() {
        s.recording = false
        s.recTimer?.invalidate(); s.recTimer = nil
    }

    func stopRecording() {
        guard #available(macOS 15, *), let rec = s.recorder as? ScreenRecorder else { return }
        s.recTimer?.invalidate(); s.recTimer = nil
        s.setStatus("Finalizing recording…", "work")
        Task { @MainActor in
            await rec.stop()
            s.recording = false
            s.recorder = nil
            if let url = rec.outputURL, fileBytes(url.path) > 1000 {
                NSSound(named: "Glass")?.play()
                if s.queue.isEmpty { s.queue = [url]; s.queueIndex = 0 }
                else { s.queue.append(url); s.queueIndex = s.queue.count - 1 }
                load(url)
            } else {
                s.setStatus("Recording produced no file — check Screen Recording permission and try again.", "err")
            }
        }
    }

    // MARK: load

    func load(_ url: URL) {
        s.inputURL = url
        s.isGif = url.pathExtension.lowercased() == "gif"
        s.loading = true
        s.setStatus("Inspecting \(url.lastPathComponent)…", "work")
        s.player.pause(); s.playing = false

        DispatchQueue.global(qos: .userInitiated).async {
            let dims = runTool(gFFprobe, ["-v","error","-select_streams","v:0","-show_entries","stream=width,height","-of","csv=p=0", url.path])
            let durStr = runTool(gFFprobe, ["-v","error","-show_entries","format=duration","-of","csv=p=0", url.path])
            let fpsStr = runTool(gFFprobe, ["-v","error","-select_streams","v:0","-show_entries","stream=r_frame_rate","-of","csv=p=0", url.path])
            let parts = dims.split(separator: ",")
            let w = parts.count > 0 ? CGFloat(Int(parts[0]) ?? 0) : 0
            let h = parts.count > 1 ? CGFloat(Int(parts[1]) ?? 0) : 0
            var dur = Double(durStr) ?? 0
            // r_frame_rate is like "30000/1001"; evaluate to a Double.
            var fps = 0.0
            let fp = fpsStr.split(separator: "/")
            if fp.count == 2, let n = Double(fp[0]), let d = Double(fp[1]), d > 0 { fps = n / d }
            else { fps = Double(fpsStr) ?? 0 }

            var previewPath = url.path
            if s.isGif {
                // Transcode GIF -> temp mp4 for smooth scrubbing.
                let tmp = NSTemporaryDirectory() + "clipeditor_preview.mp4"
                _ = runTool(gFFmpeg, ["-y","-v","error","-i",url.path,"-movflags","+faststart",
                                      "-vf","scale=trunc(iw/2)*2:trunc(ih/2)*2","-pix_fmt","yuv420p", tmp])
                previewPath = tmp
                if dur == 0 { dur = Double(runTool(gFFprobe, ["-v","error","-show_entries","format=duration","-of","csv=p=0", tmp])) ?? 0 }
            }

            DispatchQueue.main.async {
                s.srcW = w; s.srcH = h; s.duration = dur
                s.trimStart = 0; s.trimEnd = dur; s.current = 0
                s.resetCropFull()
                s.previewURL = URL(fileURLWithPath: previewPath)
                let item = AVPlayerItem(url: s.previewURL!)
                s.player.replaceCurrentItem(with: item)
                s.attachObserver()
                s.seek(0)
                s.loading = false
                s.srcFps = fps
                if !s.fpsOn { s.fpsText = fps > 0 ? String(Int(fps.rounded())) : "" }
                s.outName = "clip"
                s.setStatus("\(Int(w))×\(Int(h)), \(mmss(dur)) — drag the yellow box to crop, the handles to trim.", "info")
            }
        }
    }

    // MARK: export

    // Target fps when the checkbox is on and the field is a valid number; else nil (keep source).
    func fpsOverride() -> Int? {
        guard s.fpsOn, let v = Int(s.fpsText.trimmingCharacters(in: .whitespaces)), v > 0 else { return nil }
        return min(v, 240)
    }

    // User scale factor, clamped to (0, 1]. Invalid/0 → 1.0 (no scaling).
    func scaleFactor() -> Double {
        let f = Double(s.scale.trimmingCharacters(in: .whitespaces)) ?? 1.0
        return f <= 0 ? 1.0 : min(f, 1.0)
    }

    // Even crop dims for yuv420p, clamped to source, plus optional scale.
    // Returns the "crop=…[,scale=…]" filter, start, dur.
    func cropTrim() -> (crop: String, st: Double, dur: Double) {
        var cw = Int(s.cropW.rounded()), ch = Int(s.cropH.rounded())
        var cx = Int(s.cropX.rounded()), cy = Int(s.cropY.rounded())
        cw -= cw % 2; ch -= ch % 2
        if cx + cw > Int(s.srcW) { cx = Int(s.srcW) - cw }
        if cy + ch > Int(s.srcH) { cy = Int(s.srcH) - ch }
        cx = max(0, cx); cy = max(0, cy)
        var f = "crop=\(cw):\(ch):\(cx):\(cy)"
        let sf = scaleFactor()
        if abs(sf - 1.0) > 0.001 {
            // trunc(.../2)*2 keeps dimensions even (required by yuv420p; harmless for gif)
            f += ",scale=trunc(iw*\(sf)/2)*2:trunc(ih*\(sf)/2)*2"
        }
        return (f, s.trimStart, max(0.05, s.trimEnd - s.trimStart))
    }

    var isBatch: Bool { s.queue.count > 1 }

    // Transcribe the trimmed audio with whisper.cpp → temp .srt and .txt paths.
    // Runs on the caller's background queue. Returns (srtPath, txtPath) or nils.
    func makeCaptions(_ input: URL, _ st: Double, _ dur: Double) -> (srt: String?, txt: String?) {
        let tmp = NSTemporaryDirectory()
        let wav = tmp + "mbcap.wav"
        let base = tmp + "mbcap"
        try? FileManager.default.removeItem(atPath: base + ".srt")
        try? FileManager.default.removeItem(atPath: base + ".txt")
        // whisper wants 16 kHz mono PCM
        _ = runTool(gFFmpeg, ["-y","-v","error","-i",input.path,"-ss",String(st),"-t",String(dur),
                              "-vn","-ar","16000","-ac","1","-c:a","pcm_s16le", wav])
        guard fileBytes(wav) > 1000 else { return (nil, nil) }   // no audio track
        let env = gGgmlBackends.isEmpty ? [:] : ["GGML_BACKEND_PATH": gGgmlBackends]
        _ = runTool(gWhisper, ["-m",gWhisperModel,"-f",wav,"-osrt","-otxt","-of",base], env: env)
        let srt = base + ".srt", txt = base + ".txt"
        return (fileBytes(srt) > 0 ? srt : nil, fileBytes(txt) > 0 ? txt : nil)
    }

    // base.ext if free; otherwise base_1.ext, base_2.ext, … (first free number).
    func uniqueOutputURL(_ folder: URL, _ base: String, _ ext: String) -> URL {
        let fm = FileManager.default
        let first = folder.appendingPathComponent("\(base).\(ext)")
        if !fm.fileExists(atPath: first.path) { return first }
        var n = 1
        var candidate = folder.appendingPathComponent("\(base)_\(n).\(ext)")
        while fm.fileExists(atPath: candidate.path) {
            n += 1
            candidate = folder.appendingPathComponent("\(base)_\(n).\(ext)")
        }
        return candidate
    }

    // Pick the folder all exports go to (persists for the session).
    func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Use folder"
        panel.canCreateDirectories = true            // shows the "New Folder" button
        panel.message = "Choose where exported files are saved"
        panel.directoryURL = s.exportFolder
        if panel.runModal() == .OK, let u = panel.url { s.exportFolder = u }
    }

    // After a successful batch export, load the next clip or finish.
    func advanceAfterExport(_ savedName: String) {
        NSSound(named: "Glass")?.play()
        if s.queueIndex + 1 < s.queue.count {
            s.queueIndex += 1
            s.setStatus("Saved \(savedName) — loading clip \(s.queueIndex + 1)/\(s.queue.count)…", "ok")
            load(s.queue[s.queueIndex])
        } else {
            s.setStatus("Batch complete — \(s.queue.count) clips exported.", "ok")
        }
    }

    func export() {
        guard let input = s.inputURL else { return }
        if s.outFormat == "Web" { exportWeb(input); return }
        let (crop, st, durSel) = cropTrim()

        var fmt = s.outFormat
        if fmt == "Same as input" { fmt = s.isGif ? "GIF" : "MP4" }
        let ext = fmt == "GIF" ? "gif" : "mp4"
        let nm = s.outName.isEmpty ? input.deletingPathExtension().lastPathComponent : s.outName

        // One-click: write straight into the chosen export folder, never overwriting.
        try? FileManager.default.createDirectory(at: s.exportFolder, withIntermediateDirectories: true)
        let out = uniqueOutputURL(s.exportFolder, nm, ext)

        let quality = s.quality, fpsOv = fpsOverride()
        let burn = s.capBurn, wantSrt = s.capSrt, wantTxt = s.capTxt
        let wantCaps = burn || wantSrt || wantTxt
        let folder = s.exportFolder
        let outBase = out.deletingPathExtension().lastPathComponent
        let posLbl = isBatch ? " · clip \(s.queueIndex + 1)/\(s.queue.count)" : ""

        s.exporting = true
        s.setStatus(wantCaps ? "Transcribing…" : "Exporting \(fmt) · \(quality)\(posLbl)…", "work")
        DispatchQueue.global(qos: .userInitiated).async {
            var burnSrt: String? = nil
            if wantCaps {
                let caps = self.makeCaptions(input, st, durSel)
                if let srt = caps.srt {
                    burnSrt = srt
                    if wantSrt {
                        try? FileManager.default.copyItem(atPath: srt, toPath: self.uniqueOutputURL(folder, outBase, "srt").path)
                    }
                }
                if wantTxt, let txt = caps.txt {
                    try? FileManager.default.copyItem(atPath: txt, toPath: self.uniqueOutputURL(folder, outBase, "txt").path)
                }
                DispatchQueue.main.async { s.setStatus("Exporting \(fmt) · \(quality)\(posLbl)…", "work") }
            }
            let p = plan(fmt, quality, crop, fpsOv)
            let err = runTool(gFFmpeg, ["-y","-v","error","-i",input.path,"-ss",String(st),"-t",String(durSel),
                                        "-vf",p.vf] + args(p.codec) + [out.path])
            // Embed a soft (toggleable) subtitle track for MP4 when requested.
            if burn, ext == "mp4", let srt = burnSrt, FileManager.default.fileExists(atPath: out.path) {
                let tmp = out.path + ".subs.mp4"
                _ = runTool(gFFmpeg, ["-y","-v","error","-i",out.path,"-i",srt,"-map","0","-map","1",
                                      "-c","copy","-c:s","mov_text","-metadata:s:s:0","language=eng",
                                      "-metadata:s:s:0","title=English","-disposition:s:0","default", tmp])
                if FileManager.default.fileExists(atPath: tmp) {
                    try? FileManager.default.removeItem(atPath: out.path)
                    try? FileManager.default.moveItem(atPath: tmp, toPath: out.path)
                }
            }
            DispatchQueue.main.async {
                s.exporting = false
                if FileManager.default.fileExists(atPath: out.path) {
                    if isBatch { advanceAfterExport(out.lastPathComponent) }
                    else {
                        s.setStatus("Saved \(out.lastPathComponent)", "ok")
                        NSSound(named: "Glass")?.play()
                    }
                } else {
                    s.setStatus("Export failed: \(err.suffix(160))", "err")
                }
            }
        }
    }

    // Estimate output size by encoding a short sample at the real settings and
    // scaling by the full trim duration. Honest because CRF/VP9 sizes depend on
    // content and can't be derived from settings alone.
    func estimateSize() {
        guard let input = s.inputURL else { return }
        let (crop, st, durSel) = cropTrim()
        // Sample from ~1/4 in (skip any atypical opening) over a longer window so a
        // single keyframe doesn't dominate and inflate the extrapolation.
        let sampleDur = min(4.0, max(0.5, durSel))
        let sampleStart = st + max(0, (durSel - sampleDur) * 0.25)
        let factor = durSel / sampleDur
        var fmt = s.outFormat
        if fmt == "Same as input" { fmt = s.isGif ? "GIF" : "MP4" }
        let tmp = NSTemporaryDirectory()

        s.estimating = true
        s.setStatus("Estimating \(fmt) size…", "work")
        let quality = s.quality
        let fpsOv = fpsOverride()
        DispatchQueue.global(qos: .userInitiated).async {
            // Encode a sample with the SAME plan() settings export will use.
            func sample(_ f: String) -> Double {
                let p = plan(f, quality, crop, fpsOv)
                let o = tmp + "est." + (f == "GIF" ? "gif" : (f == "WEBM" ? "webm" : "mp4"))
                _ = runTool(gFFmpeg, ["-y","-v","error","-ss",String(sampleStart),"-i",input.path,"-t",String(sampleDur),
                                      "-vf",p.vf] + args(p.codec) + [o])
                return fileBytes(o)
            }
            var msg = ""
            switch fmt {
            case "GIF": msg = "≈ \(humanSize(sample("GIF") * factor)) GIF"
            case "Web":
                let w = sample("WEBM") * factor, g = sample("GIF") * factor
                msg = "≈ \(humanSize(w + g)) total  (webm \(humanSize(w)) + gif \(humanSize(g)))"
            default: msg = "≈ \(humanSize(sample("MP4") * factor)) MP4"
            }
            DispatchQueue.main.async {
                s.estimating = false
                s.setStatus("\(msg) · \(quality) · \(mmss(durSel)) — rough estimate; low-motion reads high", "ok")
            }
        }
    }

    // "Web": create <name>_forweb/ inside the export folder, holding a .webm and a .gif.
    func exportWeb(_ input: URL) {
        let (crop, st, durSel) = cropTrim()
        let base = s.outName.isEmpty ? input.deletingPathExtension().lastPathComponent : s.outName
        // Collision-safe folder: <base>_forweb, then _forweb_1, _forweb_2, …
        var folder = s.exportFolder.appendingPathComponent("\(base)_forweb")
        var n = 1
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = s.exportFolder.appendingPathComponent("\(base)_forweb_\(n)"); n += 1
        }
        let webm = folder.appendingPathComponent("\(base).webm")
        let gif = folder.appendingPathComponent("\(base).gif")

        let pw = plan("WEBM", s.quality, crop, fpsOverride())
        let pg = plan("GIF", s.quality, crop, fpsOverride())
        let webmArgs = ["-y","-v","error","-i",input.path,"-ss",String(st),"-t",String(durSel),"-vf",pw.vf] + args(pw.codec) + [webm.path]
        let gifArgs = ["-y","-v","error","-i",input.path,"-ss",String(st),"-t",String(durSel),"-vf",pg.vf, gif.path]

        s.exporting = true
        s.setStatus("Exporting Web · \(s.quality) → \(base)_forweb…", "work")
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let e1 = runTool(gFFmpeg, webmArgs)
            DispatchQueue.main.async { s.setStatus("webm done, building gif…", "work") }
            let e2 = runTool(gFFmpeg, gifArgs)
            DispatchQueue.main.async {
                s.exporting = false
                let okW = FileManager.default.fileExists(atPath: webm.path)
                let okG = FileManager.default.fileExists(atPath: gif.path)
                if okW && okG {
                    if isBatch { advanceAfterExport("\(base)_forweb/") }
                    else {
                        s.setStatus("Saved \(folder.lastPathComponent)/ (webm + gif)", "ok")
                        NSSound(named: "Glass")?.play()
                    }
                } else {
                    s.setStatus("Web export issue — webm:\(okW ? "ok" : "fail") gif:\(okG ? "ok" : "fail") \((e1 + e2).suffix(140))", "err")
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        resolveTools()
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

@main
struct ClipEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var state = EditorState()
    var body: some Scene {
        WindowGroup("SimpleClips") { ContentView().environmentObject(state) }
            .windowResizability(.contentSize)
    }
}
