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

// Like runTool, but also reports whether the tool exited cleanly and can hand the
// Process back via onStart (so a newer request can terminate a stale run).
@discardableResult
func runToolChecked(_ exe: String, _ args: [String], onStart: ((Process) -> Void)? = nil) -> (output: String, ok: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return ("", false) }
    onStart?(p)
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (out, p.terminationStatus == 0)
}

// Split a plan() codec string ("-c:v libx264 -crf 18 …") into argv tokens.
func args(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }

// Last "out_time=HH:MM:SS.us" value (in seconds) from streamed ffmpeg -progress text.
func lastOutTime(_ s: String) -> Double? {
    guard let r = s.range(of: "out_time=", options: .backwards) else { return nil }
    let str = s[r.upperBound...].prefix { $0 != "\n" && $0 != "\r" }
    let parts = str.split(separator: ":")
    guard parts.count == 3, let hh = Double(parts[0]), let mm = Double(parts[1]),
          let ss = Double(parts[2]) else { return nil }
    return hh * 3600 + mm * 60 + ss
}

// Run ffmpeg while streaming `-progress pipe:1`, reporting 0…1 as it encodes.
// Returns the merged output (for error reporting) AND the exit code — success is
// code == 0, not "a file exists": ffmpeg leaves a partial file behind when it dies
// mid-encode, which must never be reported as "Saved". `onStart` hands back the
// Process so the caller can terminate it (Cancel).
func runFFmpegProgress(_ args: [String], total: Double, onStart: ((Process) -> Void)? = nil,
                       onProgress: @escaping (Double) -> Void) -> (output: String, code: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: gFFmpeg)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return ("", -1) }
    onStart?(p)
    let h = pipe.fileHandleForReading
    var collected = ""
    while case let chunk = h.availableData, !chunk.isEmpty {
        collected += String(data: chunk, encoding: .utf8) ?? ""
        if total > 0, let t = lastOutTime(collected) {
            onProgress(min(1, max(0, t / total)))
        }
    }
    p.waitUntilExit()
    return (collected.trimmingCharacters(in: .whitespacesAndNewlines), p.terminationStatus)
}

// "~12s left" / "~1m 05s left" for an ETA in seconds.
func etaString(_ sec: Double) -> String {
    guard sec > 0 else { return "" }
    let s = Int(sec.rounded())
    return s >= 60 ? "~\(s / 60)m \(String(format: "%02d", s % 60))s left" : "~\(s)s left"
}

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
// format: "MP4" | "GIF" | "WEBM".  q: continuous fidelity→optimization, 0...1
//   (0 = maximum fidelity, 1 = maximum optimization; the slider drives this).
// fast: trade encoder effort for wall-clock — x264 veryfast for the H.264 family,
//   VP9 cpu-used 5 for WebM. Measured on real 4K screen content: ~2× faster than the
//   default ladder for under one VMAF point. (A VideoToolbox hardware mode was tried
//   and removed: on Apple Silicon the media engine is pixel-bound to ~100fps at 4K —
//   multi-core x264 matches it on speed and beats it badly on quality-per-byte.)
//   Ignored for GIF/MPEG-2/WMV, where effort barely moves the needle.
// Returns the -vf filtergraph and the trailing codec args.
func plan(_ format: String, _ q: Double, _ crop: String, _ fps: Int?, _ fast: Bool = false) -> (vf: String, codec: String) {
    let rate = (fps != nil) ? " -r \(fps!)" : ""
    let qq = min(max(q, 0), 1)
    switch format {
    // NOTE: the quality slider only changes compression — it NEVER alters resolution.
    // Output size is controlled entirely by the user's crop + output-size fields
    // (already baked into `crop`).
    case "GIF":
        let gfps = Int((20 - qq * 8).rounded())          // 20 → 12 fps
        let pal: String, use: String
        if qq < 0.34 {        pal = "palettegen=stats_mode=full";                use = "paletteuse=dither=sierra2_4a" }
        else if qq < 0.67 {   pal = "palettegen=stats_mode=diff";                use = "paletteuse=dither=bayer" }
        else {                pal = "palettegen=max_colors=128:stats_mode=diff"; use = "paletteuse=dither=bayer:bayer_scale=2" }
        let vf = "\(crop),fps=\(fps ?? gfps),split[a][b];[a]\(pal)[p];[b][p]\(use)"
        return (vf, "")
    case "WEBM":
        let crf = Int((18 + qq * 22).rounded())          // 18 → 40
        let ab  = Int((192 - qq * 96).rounded())         // 192 → 96 kbps
        let extra = fast ? "-row-mt 1 -deadline good -cpu-used 5"
                  : (qq > 0.67 ? "-row-mt 1 -deadline good -cpu-used 3" : "-row-mt 1")
        return (crop, "-c:v libvpx-vp9 -crf \(crf) -b:v 0 \(extra) -pix_fmt yuv420p\(rate) -c:a libopus -b:a \(ab)k")
    case "MPG":   // MPEG-1/2 program stream
        let qv = Int((2 + qq * 5).rounded())             // 2 → 7
        return (crop, "-c:v mpeg2video -q:v \(qv)\(rate) -c:a mp2 -b:a 192k")
    case "WMV":
        let qv = Int((2 + qq * 4).rounded())             // 2 → 6
        return (crop, "-c:v wmv2 -q:v \(qv)\(rate) -c:a wmav2 -b:a 192k")
    default:      // H.264/AAC family of containers: MP4, MOV, M4V, MKV, AVI, TS, FLV, F4V, 3GP
        let crf = Int((14 + qq * 16).rounded())          // 14 → 30
        let preset = fast ? "veryfast" : (qq < 0.34 ? "slow" : (qq < 0.67 ? "medium" : "slower"))
        let ab  = Int((256 - qq * 160).rounded())        // 256 → 96 kbps
        let profile = (format == "3GP") ? " -profile:v baseline -level 3.1" : ""
        let faststart = ["MP4","MOV","M4V"].contains(format) ? " -movflags +faststart" : ""
        return (crop, "-c:v libx264 -crf \(crf) -preset \(preset)\(profile) -pix_fmt yuv420p\(rate) -c:a aac -b:a \(ab)k\(faststart)")
    }
}

// Formats where the Fast-export toggle changes anything. GIF (palette passes) and the
// ancient MPEG-2/WMV encoders are already effort-insensitive.
func fastApplies(_ format: String) -> Bool {
    !["GIF", "MPG", "WMV"].contains(format)
}

// A short human label for a fidelity→optimization slider value (0...1).
func qLabel(_ q: Double) -> String {
    if q < 0.2 { return "high fidelity" }
    if q < 0.45 { return "fidelity-leaning" }
    if q <= 0.55 { return "balanced" }
    if q < 0.8 { return "optimized-leaning" }
    return "high optimization"
}

// Output file extension for a format tag.
func extFor(_ format: String) -> String {
    switch format {
    case "GIF": return "gif"
    case "WEBM": return "webm"
    case "MOV": return "mov"; case "M4V": return "m4v"; case "MKV": return "mkv"
    case "AVI": return "avi"; case "WMV": return "wmv"; case "FLV": return "flv"
    case "TS": return "ts"; case "MPG": return "mpg"; case "3GP": return "3gp"; case "F4V": return "f4v"
    default: return "mp4"
    }
}

// ---- size estimation model (mirrors the Windows engine's estimate.js) -----

// Every setting that affects output size, snapshotted so a calibration taken at one
// set of settings can be re-evaluated against the model later.
struct EstParams {
    var outFormat: String
    var quality: Double
    var outW: Int
    var outH: Int
    var srcFps: Double
    var fpsOverride: Int?      // nil = keep source rate
    var trimStart: Double
    var trimEnd: Double
    var capBurn: Bool
    // Fast export (x264 veryfast / VP9 cpu-used 5). The size model treats it as
    // size-neutral (measured within ±10% on real content, either direction), but it
    // lives in the params so a calibration taken in one mode is re-measured for the
    // other (the toggle triggers an auto-measure).
    var fast: Bool
}

// Content anchor: the source's own per-second video bytes. cum[i] = total video bytes
// before second i, so any trim range is an O(1) lookup.
struct Anchor {
    var cum: [Double]
    var total: Double
    var srcW: Double
    var srcH: Double
    var srcCrf: Double        // ~CRF 20 is typical delivered H.264 (incl. our masters)
}

// Parse ffprobe "-show_entries packet=pts_time,size -of csv=p=0" output (video stream
// only) into 1-second byte buckets. Packets with no usable timestamp fall into the
// last seen bucket.
func parsePackets(_ csv: String) -> (cum: [Double], total: Double) {
    var buckets: [Double] = []
    var total = 0.0
    var lastSec = 0
    for line in csv.split(separator: "\n") {
        guard let c = line.firstIndex(of: ",") else { continue }
        let t = Double(line[..<c])
        let sizeStr = line[line.index(after: c)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let size = Double(sizeStr), size > 0 else { continue }
        let sec = (t != nil && t!.isFinite && t! >= 0) ? Int(t!) : lastSec
        lastSec = sec
        while buckets.count <= sec { buckets.append(0) }
        buckets[sec] += size
        total += size
    }
    var cum: [Double] = [0]
    for b in buckets { cum.append(cum.last! + b) }
    return (cum, total)
}

// Instant, no-encode size model. Rough by design: scales a per-pixel-per-frame
// bitrate by the CRF curve (~6 CRF ≈ half the size).
func liveBytes(_ fmt: String, _ p: EstParams) -> Double {
    let dur = max(0.05, p.trimEnd - p.trimStart)
    let px = Double(max(2, p.outW)) * Double(max(2, p.outH))
    let src = p.srcFps > 0 ? p.srcFps : 30
    let fps = Double(p.fpsOverride ?? Int(src.rounded()))
    let q = min(max(p.quality, 0), 1)
    switch fmt {
    case "GIF":
        let gfps = 20 - q * 8
        let bpp = 0.5 - q * 0.3                       // bytes per pixel-frame (palettized)
        return px * gfps * dur * bpp
    case "WEBM":
        let crf = 18 + q * 22
        let bpp = 0.05 * pow(2.0, (31 - crf) / 6)
        let abits = (192 - q * 96) * 1000 * dur
        return (bpp * px * fps * dur + abits) / 8
    case "Web":
        return liveBytes("WEBM", p) + liveBytes("GIF", p)
    case "MPG", "WMV":
        let crf = 14 + q * 16
        let bpp = 0.08 * pow(2.0, (22 - crf) / 6) * 2.2   // older codecs ≈ 2× larger
        return (bpp * px * fps * dur + 192 * 1000 * dur) / 8
    default:                                          // H.264 family
        let crf = 14 + q * 16
        let bpp = 0.08 * pow(2.0, (22 - crf) / 6)
        let abits = (256 - q * 160) * 1000 * dur
        return (bpp * px * fps * dur + abits) / 8
    }
}

// Content-anchored estimate: scale the source's REAL bytes for the trimmed range by
// quality (the same ~6-CRF-halves-size rule), pixel ratio (sublinear: downscaled
// content keeps more detail per pixel), fps ratio (sublinear: duplicate and
// near-static frames are nearly free), and a codec factor. Returns nil when it can't
// apply (no anchor data, or GIF whose size is palette- not CRF-driven) — the caller
// falls back to liveBytes. No fixed constant can model both a static screen recording
// and camera footage (they differ by 10-30x); the clip itself is the best predictor.
func anchoredBytes(_ fmt: String, _ p: EstParams, _ anchor: Anchor?) -> Double? {
    guard let a = anchor, a.cum.count >= 2, a.total > 0 else { return nil }
    if fmt == "GIF" { return nil }
    if fmt == "Web" {
        guard let w = anchoredBytes("WEBM", p, a) else { return nil }
        return w + liveBytes("GIF", p)
    }
    let cum = a.cum
    let maxI = cum.count - 1
    func at(_ t: Double) -> Double {                  // linear interp inside buckets
        let x = clamp(t, 0, Double(maxI))
        let i = Int(x)
        return i >= maxI ? cum[maxI] : cum[i] + (cum[i + 1] - cum[i]) * (x - Double(i))
    }
    let srcBytes = max(0, at(p.trimEnd) - at(p.trimStart))
    guard srcBytes > 0 else { return nil }
    let dur = max(0.05, p.trimEnd - p.trimStart)
    let q = min(max(p.quality, 0), 1)
    let srcPx = max(2, a.srcW) * max(2, a.srcH)
    let outPx = Double(max(2, p.outW)) * Double(max(2, p.outH))
    let srcFps = p.srcFps > 0 ? p.srcFps : 30
    let fps = Double(p.fpsOverride ?? Int(srcFps.rounded()))
    // One H.264-equivalent quality curve for every codec (matches plan()'s h264 family);
    // VP9/MPEG-2/WMV efficiency differences are folded into a flat codec factor instead.
    let outCrf = 14 + q * 16
    let codecF = fmt == "WEBM" ? 0.7 : ((fmt == "MPG" || fmt == "WMV") ? 2.2 : 1.0)
    let video = srcBytes
        * pow(2, (a.srcCrf - outCrf) / 6)
        * pow(outPx / srcPx, 0.85)
        * pow(fps / srcFps, 0.6)
        * codecF
    let akbps = fmt == "WEBM" ? 192 - q * 96 : ((fmt == "MPG" || fmt == "WMV") ? 192 : 256 - q * 160)
    return video + akbps * 1000 * dur / 8
}

// Best available base estimate: content-anchored once packet data is in, model until then.
func estBase(_ fmt: String, _ p: EstParams, _ anchor: Anchor?) -> Double {
    anchoredBytes(fmt, p, anchor) ?? liveBytes(fmt, p)
}


// Rough size of an embedded soft-subtitle track (mov_text), MP4 family only. Text, so small.
func captionBytes(_ p: EstParams) -> Double {
    guard p.capBurn, ["MP4", "MOV", "M4V"].contains(p.outFormat) else { return 0 }
    return max(0.05, p.trimEnd - p.trimStart) * 30   // ≈ 30 bytes/sec of dialogue
}

// Private temp folder holding copies of imported clips, so the queue survives
// the originals being moved/deleted. Wiped on quit (see AppDelegate).
let gStashDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("SimpleClips-stash", isDirectory: true)

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
               pixelW: Int, pixelH: Int, micOn: Bool, micDeviceID: String,
               sysAudio: Bool, cursor: Bool) async throws {
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
        // Cap capture at the display's real refresh rate (120 on ProMotion, 60
        // otherwise) instead of a hard 30, clamped to 120 like the Windows build —
        // a 240Hz master gains nothing but encode time. ScreenCaptureKit is
        // variable-rate, so this is a ceiling — frames only come when the screen changes.
        let screenFps = min(120, Self.displayMaxFPS(display.displayID))
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(screenFps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = cursor
        config.captureMicrophone = micOn
        if micOn, !micDeviceID.isEmpty { config.microphoneCaptureDeviceID = micDeviceID }
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

    // The display's max refresh rate in Hz, via its NSScreen; defaults to 60.
    static func displayMaxFPS(_ id: CGDirectDisplayID) -> Int {
        if let ns = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }), ns.maximumFramesPerSecond > 0 {
            return ns.maximumFramesPerSecond
        }
        if let mode = CGDisplayCopyDisplayMode(id), mode.refreshRate > 0 {
            return Int(mode.refreshRate.rounded())
        }
        return 60
    }

    // SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("Capture stopped: \(error.localizedDescription)")
        if let c = finishContinuation { finishContinuation = nil; c.resume() }
    }
}

// ---- coalesced seeking -----------------------------------------------------

// At most ONE seek in flight per player; while the decoder works, only the LATEST
// requested time is kept. Without this, a fast drag queues stale seeks and the
// picture replays the drag in slow motion long after the mouse stopped.
final class CoalescedSeeker {
    private let player: AVPlayer
    private var busy = false
    private var pending: Double? = nil
    init(_ p: AVPlayer) { player = p }

    func to(_ t: Double) {                 // main thread only
        if busy { pending = t; return }
        busy = true
        step(t)
    }
    private func step(_ t: Double) {
        let cm = CMTime(seconds: max(0, t), preferredTimescale: 600)
        player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let next = self.pending { self.pending = nil; self.step(next) }
                else { self.busy = false }
            }
        }
    }
    func reset() { busy = false; pending = nil }   // item changed → in-flight seek never lands
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
    @Published var cropOn = false          // crop enabled? off = export the full frame
    @Published var playing = false
    @Published var loading = false
    @Published var exporting = false
    @Published var exportProgress: Double = 0   // 0…1 while exporting (determinate bar)
    @Published var exportETA = ""               // "~12s left"
    var exportProcess: Process?                 // the running ffmpeg, so Cancel can stop it
    var exportCancelled = false
    @Published var estimating = false           // a "Harder estimate" sample encode is running
    // Content anchor: the source's own per-second video bytes, fetched once per clip.
    // Makes the live estimate content-aware from load.
    @Published var anchor: Anchor? = nil
    // Calibration from a "Harder estimate": the measured bytes and the settings they were
    // measured at. The correction factor is recomputed as measured/model on every read, so
    // it stays consistent even if the model improves later (e.g. the anchor arriving).
    @Published var calibBytes: Double = 0
    @Published var calibFormat = ""
    var calibParams: EstParams? = nil
    var autoEstWork: DispatchWorkItem?           // debounced auto-measure after load
    // "Show in folder" target — only the status that saved something offers it.
    @Published var revealURL: URL? = nil
    @Published var status = "Drop video, .gif, or multiple files here."
    @Published var statusKind = "info"   // info | work | ok | err
    @Published var outFormat = "MP4"   // set to the detected input type on load
    @Published var quality: Double = 0.5  // 0 = max fidelity … 1 = max optimization (slider)
    @Published var fastExport = false  // x264 veryfast / VP9 cpu-used 5: ~2× faster encode
    @Published var outName = ""
    // Output pixel size (aspect-locked to the crop). Defaults to the crop size.
    @Published var outW: Int = 0
    @Published var outH: Int = 0
    @Published var srcFps: Double = 0      // source frame rate
    @Published var fps: Double = 30        // target fps (slider); == srcFps means "keep source"
    // captions / transcription (whisper.cpp)
    @Published var capBurn = false         // burn subtitles into the video
    @Published var capSrt = false          // save sidecar .srt
    @Published var capTxt = false          // save plain transcript .txt
    @Published var hasCaptions = false     // current clip has an embedded subtitle track
    @Published var queue: [URL] = []       // batch queue
    @Published var queueIndex = 0
    @Published var exportFolder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")

    // screen recording
    @Published var recording = false
    @Published var recElapsed: Double = 0
    @Published var screens: [(id: CGDirectDisplayID, name: String)] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var micOn = false
    @Published var micDevices: [(id: String, name: String)] = []
    @Published var micDeviceID = ""        // empty = system default microphone
    @Published var sysAudioOn = false
    @Published var cursorOn = true
    @Published var regionOn = false
    var recorder: AnyObject?               // ScreenRecorder (type-erased to avoid @available leak)
    var regionSelector: RegionSelector?
    var screenLabelWindows: [NSWindow] = []   // "identify" number overlays
    var recTimer: Timer?
    var recStart: Date?

    // Any new status retires a stale "Show in folder" offer.
    func setStatus(_ msg: String, _ kind: String = "info") { status = msg; statusKind = kind; revealURL = nil }

    let player = AVPlayer()
    var previewURL: URL?
    var timeObserver: Any?

    // Scrub proxy (tiny, densely-keyframed mp4): shown ONLY while the user drags the
    // playhead or trim handles, so scrubbing is instant even on a heavy master.
    let scrubPlayer = AVPlayer()
    @Published var scrubReady = false      // proxy built and loaded into scrubPlayer
    @Published var scrubbing = false       // a timeline drag is in progress
    var scrubURL: URL?
    var scrubBuild: Process?               // running proxy encode (killed on new load)
    lazy var mainSeeker = CoalescedSeeker(player)
    lazy var scrubSeeker = CoalescedSeeker(scrubPlayer)

    func beginScrub() { scrubbing = true }
    // While dragging, seek the low-res proxy instead of the full-res master; before
    // the proxy is ready, the coalesced seeker alone already keeps the master honest.
    func scrubTo(_ t: Double) {
        current = t
        if scrubReady { scrubSeeker.to(t) } else { mainSeeker.to(t) }
    }
    func endScrub() {
        scrubbing = false
        mainSeeker.to(current)             // full-quality frame exactly where the drag ended
    }

    func resetCropFull() { cropX = 0; cropY = 0; cropW = srcW; cropH = srcH; syncOutToCrop() }
    // Output size follows the crop (even dims). Called whenever the crop changes.
    func syncOutToCrop() {
        func ev(_ v: CGFloat) -> Int { let i = Int(v.rounded()); return max(2, i - i % 2) }
        outW = ev(cropW); outH = ev(cropH)
    }

    func attachObserver() {
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        let t = CMTime(seconds: 0.03, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: t, queue: .main) { [weak self] tm in
            guard let self = self, !self.scrubbing else { return }   // the drag owns `current`
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

    // Never show embedded subtitles in the preview: disable automatic selection and
    // deselect the legible track so a "default"-flagged track doesn't show itself.
    func applyCaptions() {
        player.appliesMediaSelectionCriteriaAutomatically = false
        guard let item = player.currentItem else { return }
        let asset = item.asset
        Task {
            let group = try? await asset.loadMediaSelectionGroup(for: .legible)
            await MainActor.run {
                guard let group = group, item == self.player.currentItem else { return }
                item.select(nil, in: group)
            }
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
    private enum Mode { case none, move, bl, br, tl, tr }   // none = empty area (ignored)
    private let grab: CGFloat = 22                     // corner hit/draw size
    private var mode: Mode = .move
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero
    // While recording: fade to a thin white outline only — no handles/label, not movable.
    var recording = false {
        didSet {
            let t = CATransition(); t.type = .fade; t.duration = 0.25
            layer?.add(t, forKey: "fade")
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true }
    required init?(coder: NSCoder) { super.init(coder: coder); wantsLayer = true }

    // The centered W×H label's background box — also the only area you can grab to MOVE.
    private func labelBox() -> NSRect {
        let txt = "\(Int(frame.width)) × \(Int(frame.height))" as NSString
        let sz = txt.size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
        return NSRect(x: (bounds.width - sz.width) / 2 - 12, y: (bounds.height - sz.height) / 2 - 9,
                      width: sz.width + 24, height: sz.height + 18)
    }

    override func draw(_ dirty: NSRect) {
        if recording {
            let outline = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)); outline.lineWidth = 1
            NSColor.white.setStroke(); outline.stroke()
            return
        }
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
        let bg = labelBox()
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        txt.draw(at: NSPoint(x: (bounds.width - sz.width)/2, y: (bounds.height - sz.height)/2), withAttributes: attrs)
    }

    // Only the corners and the center label box are interactive; the empty middle
    // returns nil so clicks pass straight through to whatever app is behind.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if recording { return nil }                 // fully click-through while recording
        let p = convert(point, from: superview)
        let left = p.x < grab, right = p.x > bounds.maxX - grab
        let bottom = p.y < grab, top = p.y > bounds.maxY - grab
        let onCorner = (left || right) && (top || bottom)
        return (onCorner || labelBox().contains(p)) ? self : nil
    }

    override func mouseDown(with e: NSEvent) {
        if recording { return }
        startMouse = NSEvent.mouseLocation
        startFrame = window?.frame ?? .zero
        let p = convert(e.locationInWindow, from: nil)
        let left = p.x < grab, right = p.x > bounds.maxX - grab
        let bottom = p.y < grab, top = p.y > bounds.maxY - grab
        if      left && bottom  { mode = .bl }
        else if right && bottom { mode = .br }
        else if left && top     { mode = .tl }
        else if right && top    { mode = .tr }
        else if labelBox().contains(p) { mode = .move }   // only the center label moves it
        else                    { mode = .none }          // empty area → no drag
    }

    override func mouseDragged(with e: NSEvent) {
        if recording || mode == .none { return }
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
        case .move, .none: break
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
    // Recording: thin white outline, non-interactive. Click-through is handled entirely
    // by RegionView.hitTest (nil everywhere while recording; nil on empty areas otherwise).
    // We deliberately do NOT toggle window.ignoresMouseEvents — flipping it true→false
    // leaves hitTest passthrough broken, which is why click-through died after recording.
    func setRecording(_ on: Bool) {
        (window.contentView as? RegionView)?.recording = on
    }

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

            Rectangle().path(in: r).stroke(Color.accentColor, lineWidth: 2)

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
        return Circle().fill(Color.accentColor).frame(width: 14, height: 14)
            .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
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
            // Before a clip loads, show the bar full width with a handle at each end.
            let hasClip = s.duration > 0
            let xStart = inset + CGFloat(hasClip ? s.trimStart / dur : 0) * W
            let xEnd = inset + CGFloat(hasClip ? s.trimEnd / dur : 1) * W
            let xCur = inset + CGFloat(hasClip ? s.current / dur : 0) * W
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.25))
                    .padding(.horizontal, inset)
                // selected region
                Rectangle().fill(Color.accentColor.opacity(0.28))
                    .frame(width: max(0, xEnd - xStart)).offset(x: xStart)
                // playhead
                Rectangle().fill(Color.primary.opacity(0.8)).frame(width: 2).offset(x: xCur - 1)
                // trim handles — wide grab area, accent-colored, with direction arrows.
                // Drags scrub via the low-res proxy (instant), then endScrub() snaps the
                // master to the exact final frame.
                handle(.right)                                  // start: ▶ points into the clip
                    .offset(x: xStart - hitW / 2)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("tl")).onChanged { g in
                        if !s.scrubbing { s.beginScrub() }
                        let t = clamp(Double((g.location.x - inset) / W) * dur, 0, s.trimEnd - 0.1)
                        s.trimStart = t; s.scrubTo(t)
                    }.onEnded { _ in s.endScrub() })
                handle(.left)                                   // end: ◀ points into the clip
                    .offset(x: xEnd - hitW / 2)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("tl")).onChanged { g in
                        if !s.scrubbing { s.beginScrub() }
                        let t = clamp(Double((g.location.x - inset) / W) * dur, s.trimStart + 0.1, s.duration)
                        s.trimEnd = t; s.scrubTo(t)
                    }.onEnded { _ in s.endScrub() })
            }
            .frame(height: barH)
            .coordinateSpace(name: "tl")
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("tl")).onChanged { g in
                // scrub playhead when dragging on the bar background (away from handles)
                let t = clamp(Double((g.location.x - inset) / W) * dur, 0, s.duration)
                if abs(g.location.x - xStart) > hitW / 2 && abs(g.location.x - xEnd) > hitW / 2 {
                    if !s.scrubbing { s.beginScrub() }
                    s.scrubTo(t)
                }
            }.onEnded { _ in if s.scrubbing { s.endScrub() } })
        }
        .frame(height: barH)
    }

    enum Dir { case left, right }
    private var hitW: CGFloat { 28 }   // generous grab width (no dead spot)
    private var barH: CGFloat { 32 }   // timeline / handle height

    func handle(_ dir: Dir) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.accentColor)
                .frame(width: 13, height: barH)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.45), lineWidth: 1))
            // grip indicator (rounded rect) instead of a direction triangle
            RoundedRectangle(cornerRadius: 1.5).fill(Color.white.opacity(0.9))
                .frame(width: 3, height: barH * 0.42)
        }
        .frame(width: hitW, height: barH)      // wide, fully-hittable grab zone
        .contentShape(Rectangle())
    }
}

// ---- main view -----------------------------------------------------------

// Subtle rounded "card" used to group a section (toolbar, sliders, output row).
struct SectionCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1))
            )
    }
}
extension View { func sectionCard() -> some View { modifier(SectionCard()) } }

struct ContentView: View {
    @EnvironmentObject var s: EditorState
    @State private var dropTargeted = false
    @State private var screenMenuOpen = false
    @State private var captionsOpen = false       // captions popover shown?
    @State private var playHover = false          // play button hover state
    @State private var recordHover = false        // record button hover state
    @State private var cancelHover = false        // cancel button hover state
    @State private var sliderColH: CGFloat = 0   // measured height of the 3-slider column
    @FocusState private var outFocus: Int?   // 1 = width field, 2 = height field, 3 = fps field

    var body: some View {
        VStack(spacing: 10) {
            // recording controls — toolbar-style bar
            if #available(macOS 15, *) {
                HStack(spacing: 10) {
                    if s.recording {
                        Text("● REC").font(.system(size: 11, weight: .bold)).foregroundColor(.red)
                        Spacer()
                        Button(action: { stopRecording() }) {
                            Label("Stop  \(mmss(s.recElapsed))", systemImage: "stop.fill")
                        }.tint(.red).buttonStyle(.borderedProminent)
                    } else {
                        // Fullscreen ↔ Region mode (Region left, Fullscreen right; default fullscreen).
                        Picker("", selection: $s.regionOn) {
                            Text("Region").tag(true)
                            Text("Fullscreen").tag(false)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                        .onChange(of: s.regionOn) { on in toggleRegion(on) }
                        // Screen picker — enabled for fullscreen, grayed out for region.
                        if !s.screens.isEmpty {
                            Button(action: { screenMenuOpen.toggle() }) {
                                HStack(spacing: 4) {
                                    Text("Screen \(currentScreenIndex)")
                                    Image(systemName: "chevron.down").font(.system(size: 9))
                                }
                            }
                            .disabled(s.regionOn)
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
                        Divider().frame(height: 16)
                        Toggle("Mic", isOn: $s.micOn).toggleStyle(.checkbox)
                            .onChange(of: s.micOn) { on in if on { enumerateMics() } }
                        // Pick which microphone (matches the Windows build).
                        if s.micOn && !s.micDevices.isEmpty {
                            Picker("", selection: $s.micDeviceID) {
                                ForEach(s.micDevices, id: \.id) { d in Text(d.name).tag(d.id) }
                            }.labelsHidden().frame(maxWidth: 150)
                        }
                        Toggle("Screen audio", isOn: $s.sysAudioOn).toggleStyle(.checkbox)
                        Toggle("Cursor", isOn: $s.cursorOn).toggleStyle(.checkbox)
                        Spacer()
                        Button(action: { startRecording() }) {
                            Label("Record Screen", systemImage: "record.circle")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(recordHover ? .white : .red)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(recordHover ? Color.red : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15), lineWidth: 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { h in withAnimation(.easeInOut(duration: 0.075)) { recordHover = h } }
                    }
                }
                .font(.system(size: 12))
                .sectionCard()
            }

            // Preview + clip bar + timeline as one attached unit (single border).
            VStack(spacing: 0) {
                // preview + crop
                GeometryReader { geo in
                    ZStack {
                        Color.black
                        PlayerView(player: s.player)
                        // The scrub proxy sits on top, visible only mid-drag; the master
                        // underneath settles on the exact frame when the drag ends.
                        PlayerView(player: s.scrubPlayer)
                            .opacity(s.scrubbing && s.scrubReady ? 1 : 0)
                            .allowsHitTesting(false)
                        if s.srcW > 0 && s.cropOn { CropOverlay(container: geo.size).environmentObject(s) }
                        if s.inputURL == nil {
                            VStack(spacing: 8) {
                                Image(systemName: "film").font(.system(size: 40)).foregroundColor(.white.opacity(0.4))
                                Text("Drop video, .gif, or multiple files here").foregroundColor(.white.opacity(0.5))
                            }
                        }
                        if s.loading {
                            Text("Loading preview…").padding(8).background(.black.opacity(0.6))
                                .foregroundColor(.white).cornerRadius(4)
                        }
                    }
                    .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
                        loadDropped(providers); return true
                    }
                }
                // The preview is the ONLY flexible row — it absorbs all vertical resizing,
                // so the fixed top/bottom controls are never clipped.
                .frame(minHeight: 180)
                .layoutPriority(-1)
                .zIndex(1)   // crop dots overflow the bottom edge → keep them above the clip bar

                Divider()   // single separator between the preview and the controls block

                // clip bar — name, captions note, crop toggle, queue nav, remove
                if !s.queue.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "square.stack.3d.up.fill").foregroundColor(.accentColor)
                        Text("Clip \(s.queueIndex + 1) of \(s.queue.count): \(s.inputURL?.lastPathComponent ?? "")")
                            .font(.system(size: 11, weight: .medium)).lineLimit(1)
                        if s.hasCaptions {
                            Text("(has captions)").font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        Spacer()
                        if s.srcW > 0 {
                            Toggle("Crop", isOn: $s.cropOn).toggleStyle(.button).font(.system(size: 11))
                                .disabled(s.exporting)
                                .onChange(of: s.cropOn) { on in if !on { s.resetCropFull() } }
                                .help("Show the crop box. Off exports the full frame.")
                            if s.cropOn {
                                Text("\(evenInt(s.cropW))×\(evenInt(s.cropH))")
                                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                                Button("Reset crop") { s.resetCropFull() }.font(.system(size: 11))
                                    .help("Reset the crop to the full frame.")
                            }
                        }
                        if s.queue.count > 1 {
                            Button("◀︎ Prev") { navQueue(-1) }.disabled(s.queueIndex == 0 || s.exporting)
                            Button("Next ▶︎") { navQueue(1) }.disabled(s.queueIndex >= s.queue.count - 1 || s.exporting)
                        }
                        Button("Remove") { removeCurrent() }.disabled(s.exporting)
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor))
                }

                // play + trim bar, with the time / trim readout right beneath it
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        Button(action: { s.togglePlay() }) {
                            Image(systemName: s.playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(playHover ? .white : .accentColor)
                                .frame(width: 32, height: 32)          // square, same height as the trim bar
                                // fades to a blue fill + white glyph on hover
                                .background(playHover ? Color(red: 0.20, green: 0.45, blue: 0.85) : Color.clear)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .overlay(Rectangle().stroke(Color.primary.opacity(0.12), lineWidth: 1))  // hard corners
                        .onHover { h in withAnimation(.easeInOut(duration: 0.075)) { playHover = h } }
                        .disabled(s.inputURL == nil)
                        Timeline().environmentObject(s)
                    }
                    HStack {
                        Text("Time  \(mmss(s.current)) / \(mmss(s.duration))")
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                        Spacer()
                        Text("Trim  \(mmss(s.trimStart)) → \(mmss(s.trimEnd))  (\(mmss(s.trimEnd - s.trimStart)))")
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
                // keep output size following the crop while you adjust the crop box
                .onChange(of: s.cropW) { _ in s.syncOutToCrop() }
                .onChange(of: s.cropH) { _ in s.syncOutToCrop() }
            }
            .overlay(Rectangle().stroke(
                dropTargeted ? Color.accentColor : Color.primary.opacity(0.12),
                lineWidth: dropTargeted ? 2 : 1))
            // thick glassy bezel around the whole preview/clip/trim unit
            .padding(6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)

            // Sliders (left) + estimate card spanning all three (right ~25%).
            // The resolution slider scales the crop down; never up past it.
            if s.srcW > 0 {
                let cw = evenInt(s.cropW), ch = evenInt(s.cropH)
                let aspect = ch > 0 ? Double(cw) / Double(ch) : 1
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Text("Resolution").font(.system(size: 11)).foregroundColor(.secondary)
                                .frame(width: 70, alignment: .leading)
                            Slider(value: Binding(
                                get: { cw > 0 ? min(100, Double(s.outW) / Double(cw) * 100) : 100 },
                                set: { pct in
                                    let f = max(0.1, min(1.0, pct / 100))
                                    s.outW = evenInt(CGFloat(Double(cw) * f))
                                    s.outH = evenInt(CGFloat(Double(ch) * f))
                                }), in: 10...100, step: 1).disabled(s.exporting)
                            Text("\(cw > 0 ? Int((Double(s.outW) / Double(cw) * 100).rounded()) : 100)%")
                                .font(.system(size: 11, design: .monospaced)).frame(width: 40, alignment: .trailing)
                            // Output pixels — editing one field auto-adjusts the other (aspect
                            // locked), capped at the crop size: downscale only, never upscale.
                            TextField("", value: Binding(
                                get: { s.outW },
                                set: { v in let w = min(cw, max(2, v - v % 2)); s.outW = w
                                            let h = Int((Double(w) / aspect).rounded()); s.outH = min(ch, max(2, h - h % 2)) }),
                                format: .number).textFieldStyle(.roundedBorder).frame(width: 52)
                                .disabled(s.exporting).focused($outFocus, equals: 1)
                            Text("×").font(.system(size: 11)).foregroundColor(.secondary)
                            TextField("", value: Binding(
                                get: { s.outH },
                                set: { v in let h = min(ch, max(2, v - v % 2)); s.outH = h
                                            let w = Int((Double(h) * aspect).rounded()); s.outW = min(cw, max(2, w - w % 2)) }),
                                format: .number).textFieldStyle(.roundedBorder).frame(width: 52)
                                .disabled(s.exporting).focused($outFocus, equals: 2)
                            Text("px").font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        HStack(spacing: 8) {
                            Text("Optimized").font(.system(size: 11)).foregroundColor(.secondary)
                                .frame(width: 70, alignment: .leading)
                            // Inverted so the knob reads left=optimized, right=fidelity,
                            // while s.quality stays 0=fidelity … 1=optimization underneath.
                            Slider(value: Binding(get: { 1 - s.quality },
                                                  set: { s.quality = 1 - $0 }), in: 0...1)
                                .disabled(s.exporting)
                            Text("Fidelity").font(.system(size: 11)).foregroundColor(.secondary)
                                .frame(width: 64, alignment: .trailing)
                        }
                        HStack(spacing: 8) {
                            Text("FPS").font(.system(size: 11)).foregroundColor(.secondary)
                                .frame(width: 70, alignment: .leading)
                            // Max = the source fps (you can only reduce fps, never add frames).
                            Slider(value: $s.fps, in: 1...max(2, s.srcFps), step: 1)
                                .disabled(s.inputURL == nil || s.exporting)
                            // Typeable too (like Windows): clamped to 1…source rate — downscale only.
                            TextField("", value: Binding(
                                get: { Int(s.fps.rounded()) },
                                set: { v in let maxFps = Int(max(2, s.srcFps).rounded())
                                            s.fps = Double(min(maxFps, max(1, v))) }),
                                format: .number).textFieldStyle(.roundedBorder).frame(width: 40)
                                .disabled(s.inputURL == nil || s.exporting).focused($outFocus, equals: 3)
                            Text("fps").font(.system(size: 11)).foregroundColor(.secondary)
                                .frame(width: 20, alignment: .leading)
                        }
                    }
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { sliderColH = g.size.height }
                            .onChange(of: g.size.height) { h in sliderColH = h }
                    })
                    // Export speed choice (vertical, between the sliders and the
                    // estimate). For GIF/MPG/WMV — where encoder effort changes nothing —
                    // the Fast option alone grays out and Best compression shows
                    // selected; the preference returns with an effort-sensitive format.
                    Divider().frame(height: sliderColH > 0 ? sliderColH : nil)
                    VStack(alignment: .leading, spacing: 8) {
                        speedOption(true, "Fast export", "about twice as fast")
                        speedOption(false, "Best compression", "slower, smallest file")
                    }
                    .frame(height: sliderColH > 0 ? sliderColH : nil, alignment: .center)
                    // Estimate card: locked to the height of the three sliders.
                    liveReadout.frame(width: 230, height: sliderColH > 0 ? sliderColH : nil)
                }
                .sectionCard()
            }

            // "Output" (left) + name / captions / format / location / export (right).
            HStack(spacing: 8) {
                Text("Output").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Text("Name").font(.system(size: 11)).foregroundColor(.secondary)
                TextField("output name", text: $s.outName)
                    .textFieldStyle(.roundedBorder).frame(width: 130).disabled(s.exporting)
                captionsMenu
                exportControls
            }
            .sectionCard()

            statusBar
        }
        .padding(14)
        .frame(minWidth: 620, minHeight: 620)
        .contentShape(Rectangle())
        .onTapGesture { outFocus = nil }   // click anywhere outside the fields to deselect
        .onAppear { enumerateScreens() }
    }

    func evenInt(_ v: CGFloat) -> Int { let i = Int(v.rounded()); return max(2, i - i % 2) }

    // One export-speed radio row. The selection shown is the EFFECTIVE mode (Best
    // compression whenever the format ignores encoder effort), not the raw preference.
    func speedOption(_ fast: Bool, _ title: String, _ sub: String) -> some View {
        let enabled = !fast || fastApplies(s.outFormat)
        let selected = (s.fastExport && fastApplies(s.outFormat)) == fast
        return Button(action: {
            let before = s.fastExport && fastApplies(s.outFormat)
            s.fastExport = fast
            // A calibration measured in the other mode is only a model-transferred
            // guess for this one — re-measure so the number snaps to reality.
            if before != (fast && fastApplies(s.outFormat)) { scheduleAutoEstimate() }
        }) {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundColor(selected ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11))
                    Text(sub).font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(s.exporting || !enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(fast
              ? (enabled ? "Encode with less effort (x264 veryfast) — about twice as fast, with a barely measurable quality difference. Size can land a little above or below Best compression."
                         : "\(s.outFormat) encodes the same way regardless of effort, so fast mode doesn't apply.")
              : "Spend full encoder effort for the smallest file at the chosen quality.")
    }

    // Snapshot of every size-affecting setting (feeds the model + calibration).
    func estParams() -> EstParams {
        EstParams(outFormat: s.outFormat, quality: s.quality, outW: s.outW, outH: s.outH,
                  srcFps: s.srcFps, fpsOverride: fpsOverride(),
                  trimStart: s.trimStart, trimEnd: s.trimEnd, capBurn: s.capBurn,
                  fast: s.fastExport && fastApplies(s.outFormat))   // effective, not the raw preference
    }

    // Displayed estimate: best base (anchored when packet data is in, model until then),
    // corrected by the measured/model ratio AT THE MEASURED SETTINGS so the number stays
    // locked onto the last real measurement and extrapolates sensibly as sliders move.
    func shownEstimate() -> (bytes: Double, calibrated: Bool) {
        let p = estParams()
        var base = estBase(s.outFormat, p, s.anchor)
        var calibrated = false
        if s.calibBytes > 0, s.calibFormat == s.outFormat, let cp = s.calibParams {
            let m = estBase(s.outFormat, cp, s.anchor)
            if m > 0 { base *= s.calibBytes / m; calibrated = true }
        }
        return (base + captionBytes(p), calibrated)
    }

    // Compact estimate card — sits to the right of the three sliders, height-locked
    // to them. Two text lines + the Harder-estimate button so it never grows taller.
    @ViewBuilder var liveReadout: some View {
        if let input = s.inputURL {
            let est = shownEstimate()
            let orig = fileBytes(input.path)
            let savings = orig > 0 ? (1 - est.bytes / orig) * 100 : 0
            let layer = s.estimating ? "measuring…"
                : (est.calibrated ? "calibrated" : (s.anchor != nil ? "live" : "rough"))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: est.calibrated ? "checkmark.seal.fill" : "wand.and.stars")
                        .font(.system(size: 11)).foregroundColor(.accentColor)
                    Text("≈ \(humanSize(est.bytes))").font(.system(size: 13, weight: .semibold))
                    Text(s.outFormat).font(.system(size: 10)).foregroundColor(.secondary)
                    if orig > 0 {
                        Text(savings >= 0 ? "−\(Int(savings.rounded()))%" : "+\(Int((-savings).rounded()))%")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(savings >= 0 ? .green : .orange)
                    }
                }
                Text("\(orig > 0 ? "was \(humanSize(orig)) · " : "")\(qLabel(s.quality)) · \(layer)")
                    .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                Spacer(minLength: 2)
                Button(s.estimating ? "Measuring…" : "Harder estimate") { hardEstimate() }
                    .font(.system(size: 11)).frame(maxWidth: .infinity)
                    .disabled(s.exporting || s.estimating)
                    .help("Encode short real samples for a more accurate number, then keep the live estimate calibrated to them.")
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.10)))
        }
    }

    // Caption options as a dropdown of checkboxes (fits on the export row).
    var captionsLabel: String {
        let n = [s.capBurn, s.capSrt, s.capTxt].filter { $0 }.count
        return n > 0 ? "Generate captions (\(n))" : "Generate captions"
    }
    // A popover (not a Menu) so it stays open while you tick several boxes;
    // clicking outside dismisses it.
    @ViewBuilder var captionsMenu: some View {
        Button(action: { captionsOpen.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: "captions.bubble")
                Text(captionsLabel)
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
        }
        .disabled(s.exporting)
        .popover(isPresented: $captionsOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Embed subs", isOn: $s.capBurn).toggleStyle(.checkbox)
                    .help("Embed a toggleable subtitle track in the MP4 (mov_text). MP4 only.")
                Toggle("Save .srt", isOn: $s.capSrt).toggleStyle(.checkbox)
                    .help("Save a separate .srt subtitle file next to the export.")
                Toggle("Transcript (.txt)", isOn: $s.capTxt).toggleStyle(.checkbox)
                    .help("Save the spoken text as a .txt file.")
                if (s.capBurn || s.capSrt || s.capTxt) && !whisperAvailable {
                    Divider()
                    Text("⚠︎ whisper not found").font(.system(size: 10)).foregroundColor(.orange)
                } else if s.capBurn || s.capSrt || s.capTxt {
                    Divider()
                    Text("Adds a transcription pass").font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            .padding(12)
        }
    }

    // Format picker + export location + Export button — lives in the bottom-right bar.
    @ViewBuilder var exportControls: some View {
        Picker("", selection: $s.outFormat) {
            Section {
                Text("MP4").tag("MP4")
                Text("GIF").tag("GIF")
                Text("WebM").tag("WEBM")
                Text("Web (webm + gif)").tag("Web")
            }
            Section("More formats") {
                Text("MOV").tag("MOV")
                Text("M4V").tag("M4V")
                Text("MKV").tag("MKV")
                Text("AVI").tag("AVI")
                Text("WMV").tag("WMV")
                Text("FLV").tag("FLV")
                Text("MPEG-TS (.ts)").tag("TS")
                Text("MPEG (.mpg)").tag("MPG")
                Text("3GP").tag("3GP")
                Text("F4V").tag("F4V")
            }
        }.frame(width: 120).labelsHidden().disabled(s.exporting)
        Button(action: { chooseExportFolder() }) {
            Label(s.exportFolder.lastPathComponent, systemImage: "folder")
        }.disabled(s.exporting).help("Set export location (currently: \(s.exportFolder.path))")
            .lineLimit(1)
        Button(s.exporting ? "Exporting…" : (s.queue.count > 1 ? "Export & Next" : "Export")) { export() }
            .buttonStyle(.borderedProminent)
            .disabled(s.inputURL == nil || s.exporting)
    }

    // While idle with a clip loaded, the bar summarizes the current state + tips
    // instead of the stale load message.
    var idleHint: String {
        guard let input = s.inputURL else { return s.status }
        let res = "\(Int(s.srcW))×\(Int(s.srcH))"
        let len = mmss(s.trimEnd - s.trimStart)
        let src = humanSize(fileBytes(input.path))
        return "\(res) · \(len) · \(src) source — drag the handles to trim; lower the sliders to shrink the file."
    }

    // Bottom feedback bar: a determinate progress bar while exporting, spinner while
    // working, colored result otherwise.
    var statusBar: some View {
        // Show the live state summary when idle with a clip; transient messages otherwise.
        let showHint = s.inputURL != nil && s.statusKind == "info"
        let determinate = s.exporting && s.exportProgress > 0
        return HStack(spacing: 8) {
            if determinate {
                Image(systemName: "square.and.arrow.down.fill").foregroundColor(.accentColor)
            } else {
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
            }
            Text(determinate ? s.status : (showHint ? idleHint : s.status))
                .font(.system(size: 11))
                .foregroundColor(s.statusKind == "ok" ? .green : (s.statusKind == "err" ? .red : .secondary))
                .lineLimit(2)
            // Only the status that just saved something offers this (cleared by the next status).
            if let r = s.revealURL, !s.exporting {
                Button("Show in folder") { NSWorkspace.shared.activateFileViewerSelecting([r]) }
                    .font(.system(size: 11))
            }
            if determinate {
                ProgressView(value: s.exportProgress).frame(width: 150)
                Text("\(Int(s.exportProgress * 100))%\(s.exportETA.isEmpty ? "" : "  \(s.exportETA)")")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            }
            Spacer()
            if s.exporting {
                Button(action: { cancelExport() }) {
                    Text("Cancel")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(cancelHover ? .white : .red)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(cancelHover ? Color.red : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { h in withAnimation(.easeInOut(duration: 0.075)) { cancelHover = h } }
                .disabled(s.exportCancelled)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.12)))
    }

    // MARK: queue

    static let acceptedExts: Set<String> = [
        "mp4","mov","m4v","gif","webm","mkv","avi","wmv","flv","ts","mts","m2ts",
        "mpg","mpeg","m2v","3gp","3g2","ogv","vob","asf","f4v","divx","qt","mxf","dv","y4m"]
    // AVPlayer can play these directly; anything else gets a proxy preview transcode.
    static let nativePreviewExts: Set<String> = ["mp4","mov","m4v"]

    func videoFiles(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { Self.acceptedExts.contains($0.pathExtension.lowercased()) }
    }

    // Collect every dropped file/folder and APPEND to the queue (don't replace).
    // Jumps to the first newly-added clip so you see what you just dropped.
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
            let stashed = files.map { self.stash($0) }   // copy in so originals can move/vanish
            let firstNew = s.queue.count          // index where the new clips start
            s.queue += stashed
            s.queueIndex = firstNew
            load(s.queue[firstNew])
        }
    }

    // Copy an imported file into our own stash so the queue keeps working even
    // if the user later moves or deletes the original. Falls back to the
    // original path if the copy fails for any reason.
    func stash(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: gStashDir, withIntermediateDirectories: true)
        let dst = gStashDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        do { try FileManager.default.copyItem(at: url, to: dst); return dst }
        catch { return url }
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
            s.scrubBuild?.terminate(); s.scrubBuild = nil
            s.scrubReady = false; s.scrubURL = nil; s.scrubbing = false
            s.scrubPlayer.replaceCurrentItem(with: nil)
            s.anchor = nil; s.calibBytes = 0; s.calibParams = nil; s.calibFormat = ""
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
                try await rec.start(displayID: displayID, sourceRect: sourceRect, pixelW: pxW, pixelH: pxH,
                                    micOn: s.micOn, micDeviceID: s.micDeviceID,
                                    sysAudio: s.sysAudioOn, cursor: s.cursorOn)
                s.recording = true
                if s.regionOn { s.regionSelector?.setRecording(true) }   // fade region UI to a thin outline
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
        s.regionSelector?.setRecording(false)
        s.recTimer?.invalidate(); s.recTimer = nil
    }

    func stopRecording() {
        guard #available(macOS 15, *), let rec = s.recorder as? ScreenRecorder else { return }
        s.recTimer?.invalidate(); s.recTimer = nil
        s.setStatus("Finalizing recording…", "work")
        Task { @MainActor in
            await rec.stop()
            s.recording = false
            s.regionSelector?.setRecording(false)
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
        // Stale estimate data must never price a different clip.
        s.anchor = nil
        s.calibBytes = 0; s.calibParams = nil; s.calibFormat = ""
        s.autoEstWork?.cancel()
        // Reset the scrub machinery for the new clip (kill an in-flight proxy build).
        s.scrubBuild?.terminate(); s.scrubBuild = nil
        s.scrubReady = false; s.scrubURL = nil; s.scrubbing = false
        s.scrubPlayer.replaceCurrentItem(with: nil)
        s.mainSeeker.reset(); s.scrubSeeker.reset()

        DispatchQueue.global(qos: .userInitiated).async {
            let dims = runTool(gFFprobe, ["-v","error","-select_streams","v:0","-show_entries","stream=width,height","-of","csv=p=0", url.path])
            let durStr = runTool(gFFprobe, ["-v","error","-show_entries","format=duration","-of","csv=p=0", url.path])
            // r_frame_rate is the *nominal* rate from the container timescale —
            // for ScreenCaptureKit .mov files that's a bogus 600. avg_frame_rate
            // is the true measured rate (frames ÷ duration), so prefer it.
            let rFpsStr = runTool(gFFprobe, ["-v","error","-select_streams","v:0","-show_entries","stream=r_frame_rate","-of","csv=p=0", url.path])
            let avgFpsStr = runTool(gFFprobe, ["-v","error","-select_streams","v:0","-show_entries","stream=avg_frame_rate","-of","csv=p=0", url.path])
            // Embedded subtitle/caption track? (any subtitle stream → yes)
            let subStr = runTool(gFFprobe, ["-v","error","-select_streams","s","-show_entries","stream=index","-of","csv=p=0", url.path])
            let hasSubs = !subStr.isEmpty
            let parts = dims.split(separator: ",")
            let w = parts.count > 0 ? CGFloat(Int(parts[0]) ?? 0) : 0
            let h = parts.count > 1 ? CGFloat(Int(parts[1]) ?? 0) : 0
            var dur = Double(durStr) ?? 0
            // Rates come as "30000/1001" or "29.7"; evaluate either form to a Double.
            func rate(_ str: String) -> Double {
                let p = str.split(separator: "/")
                if p.count == 2, let n = Double(p[0]), let d = Double(p[1]), d > 0 { return n / d }
                return Double(str) ?? 0
            }
            let avgFps = rate(avgFpsStr), rFps = rate(rFpsStr)
            // Prefer the measured average; fall back to nominal only if it's absent.
            var fps = avgFps > 0 ? avgFps : rFps
            fps = (fps * 100).rounded() / 100

            // AVPlayer only decodes mp4/mov/m4v. For anything else (webm, mkv, avi,
            // gif, wmv, …) make a fast hardware proxy mp4 so the preview/scrubbing
            // works. Editing/export still run on the ORIGINAL file at full quality.
            var previewPath = url.path
            let ext = url.pathExtension.lowercased()
            if !Self.nativePreviewExts.contains(ext) {
                let tmp = NSTemporaryDirectory() + "scpreview_\(abs(url.path.hashValue)).mp4"
                _ = runTool(gFFmpeg, ["-y","-v","error","-i",url.path,
                                      "-vf","scale=trunc(iw/2)*2:trunc(ih/2)*2",
                                      "-c:v","h264_videotoolbox","-b:v","8M","-pix_fmt","yuv420p",
                                      "-c:a","aac","-movflags","+faststart", tmp])
                previewPath = tmp
                if dur == 0 { dur = Double(runTool(gFFprobe, ["-v","error","-show_entries","format=duration","-of","csv=p=0", tmp])) ?? 0 }
            }

            DispatchQueue.main.async {
                s.srcW = w; s.srcH = h; s.duration = dur
                s.trimStart = 0; s.trimEnd = dur; s.current = 0
                s.cropOn = false            // crop is opt-in per clip
                s.resetCropFull()
                s.previewURL = URL(fileURLWithPath: previewPath)
                s.player.appliesMediaSelectionCriteriaAutomatically = false   // don't auto-show "default" subs
                let item = AVPlayerItem(url: s.previewURL!)
                s.player.replaceCurrentItem(with: item)
                s.attachObserver()
                s.seek(0)
                s.loading = false
                s.srcFps = fps
                // Default the export rate to ≤60 (universally playable: H.264 above 60fps
                // at screen resolutions crosses Level 5.2); the slider still reaches the
                // source rate for deliberate high-fps exports.
                s.fps = fps > 0 ? min(fps, 60) : 30
                // Native previews (mp4/mov/m4v) carry the subtitle track; the proxy doesn't.
                s.hasCaptions = hasSubs && Self.nativePreviewExts.contains(ext)
                s.applyCaptions()            // never show subtitles in the preview
                s.outName = "clip"
                // default output to the detected input type
                s.outFormat = (ext == "gif") ? "GIF" : (ext == "webm" ? "WEBM" : "MP4")
                s.setStatus("Loaded \(url.lastPathComponent)", "info")
                // Background workers: the content anchor (honest live estimate), the scrub
                // proxy (instant dragging), and an automatic measured calibration.
                self.fetchAnchor(url)
                self.buildScrubProxy(url)
                self.scheduleAutoEstimate()
            }
        }
    }

    // Content anchor (per-second source video bytes; demux only, so it's fast even for
    // long files). Arrives async — the estimate uses the rough model until then.
    func fetchAnchor(_ url: URL) {
        let w = Double(s.srcW), h = Double(s.srcH)
        DispatchQueue.global(qos: .utility).async {
            let csv = runTool(gFFprobe, ["-v","error","-select_streams","v:0",
                                         "-show_entries","packet=pts_time,size","-of","csv=p=0", url.path])
            let (cum, total) = parsePackets(csv)
            DispatchQueue.main.async {
                guard s.inputURL == url, total > 0 else { return }
                // ~CRF 20 is typical delivered H.264 (incl. our recording masters); it only
                // shifts the anchor's baseline — the measured calibration absorbs residue.
                s.anchor = Anchor(cum: cum, total: total, srcW: w, srcH: h, srcCrf: 20)
            }
        }
    }

    // Scrub proxy: ≤640px / 15fps / keyframe every ~0.5s, no audio — any seek decodes a
    // handful of tiny frames, so dragging is effectively instant. Built quietly in the
    // background; the UI scrubs the master until it's ready. Cached by path+size.
    func buildScrubProxy(_ url: URL) {
        let srcW = Double(s.srcW), srcH = Double(s.srcH)
        DispatchQueue.global(qos: .utility).async {
            let key = "\(url.path):\(Int(fileBytes(url.path)))"
            let out = NSTemporaryDirectory() + "scscrub_\(abs(key.hashValue)).mp4"
            if fileBytes(out) <= 1000 {
                var w = srcW > 0 ? srcW : 1280, h = srcH > 0 ? srcH : 720
                let longSide = max(w, h)
                if longSide > 640 { let f = 640 / longSide; w = (w * f).rounded(); h = (h * f).rounded() }
                let ew = max(2, Int(w) - Int(w) % 2), eh = max(2, Int(h) - Int(h) % 2)
                let res = runToolChecked(gFFmpeg,
                    ["-y","-v","error","-i",url.path,
                     "-vf","fps=15,scale=\(ew):\(eh)",
                     "-c:v","h264_videotoolbox","-b:v","1M","-g","8",
                     "-pix_fmt","yuv420p","-an","-movflags","+faststart", out],
                    onStart: { p in DispatchQueue.main.async { s.scrubBuild = p } })
                // A killed/failed encode must not poison the cache.
                if !res.ok || fileBytes(out) <= 1000 { try? FileManager.default.removeItem(atPath: out) }
            }
            DispatchQueue.main.async {
                s.scrubBuild = nil
                guard s.inputURL == url, fileBytes(out) > 1000 else { return }
                s.scrubURL = URL(fileURLWithPath: out)
                s.scrubPlayer.replaceCurrentItem(with: AVPlayerItem(url: s.scrubURL!))
                s.scrubSeeker.reset()
                s.scrubReady = true
            }
        }
    }

    // Measure a real sample at the current settings shortly after load, so the size
    // estimate is honest from the moment the clip opens. Debounced so flipping through
    // a batch only measures the clip you land on.
    func scheduleAutoEstimate() {
        s.autoEstWork?.cancel()
        let work = DispatchWorkItem {
            if s.estimating { self.scheduleAutoEstimate() }   // wait for the prior measure
            else { self.hardEstimate() }
        }
        s.autoEstWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // Capturable microphones for the recording toolbar's device picker.
    func enumerateMics() {
        if #available(macOS 14, *) {
            let ds = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                      mediaType: .audio, position: .unspecified)
            s.micDevices = ds.devices.map { (id: $0.uniqueID, name: $0.localizedName) }
        } else {
            s.micDevices = AVCaptureDevice.devices(for: .audio).map { (id: $0.uniqueID, name: $0.localizedName) }
        }
        if !s.micDevices.contains(where: { $0.id == s.micDeviceID }) {
            s.micDeviceID = s.micDevices.first?.id ?? ""
        }
    }

    // MARK: export

    // Target fps from the slider; nil (keep source) when it sits at the source rate.
    func fpsOverride() -> Int? {
        let v = Int(s.fps.rounded())
        guard v > 0 else { return nil }
        if s.srcFps > 0, abs(Double(v) - s.srcFps) < 0.5 { return nil }   // at source → no -r
        return min(v, 240)
    }

    // Even crop dims for yuv420p, clamped to source, then scale to the user's
    // chosen output pixels (aspect-locked to the crop). Returns "crop=…[,scale=…]".
    func cropTrim() -> (crop: String, st: Double, dur: Double) {
        var cw = Int(s.cropW.rounded()), ch = Int(s.cropH.rounded())
        var cx = Int(s.cropX.rounded()), cy = Int(s.cropY.rounded())
        cw -= cw % 2; ch -= ch % 2
        if cx + cw > Int(s.srcW) { cx = Int(s.srcW) - cw }
        if cy + ch > Int(s.srcH) { cy = Int(s.srcH) - ch }
        cx = max(0, cx); cy = max(0, cy)
        var f = "crop=\(cw):\(ch):\(cx):\(cy)"
        let ow = max(2, s.outW - s.outW % 2), oh = max(2, s.outH - s.outH % 2)
        if s.outW > 0, s.outH > 0, ow != cw || oh != ch {
            f += ",scale=\(ow):\(oh):flags=lanczos"
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
        // whisper wants 16 kHz mono PCM (-ss before -i: fast keyframe seek)
        _ = runTool(gFFmpeg, ["-y","-v","error","-ss",String(st),"-i",input.path,"-t",String(dur),
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

    // After a successful export: with more clips queued, advance to the next; otherwise
    // show "Saved to <full path>" with a Show-in-folder button. The message is always
    // about THE CLIP just exported — never a generic "Batch complete".
    func advanceAfterExport(_ savedName: String, _ savedURL: URL) {
        NSSound(named: "Glass")?.play()
        if s.queue.count > 1, s.queueIndex + 1 < s.queue.count {
            s.queueIndex += 1
            s.setStatus("Saved \(savedName) — loading clip \(s.queueIndex + 1)/\(s.queue.count)…", "ok")
            load(s.queue[s.queueIndex])
        } else {
            s.setStatus("Saved to \(savedURL.path)", "ok")
            s.revealURL = savedURL
        }
    }

    // Stop the in-progress export: flag it and terminate the running ffmpeg.
    func cancelExport() {
        s.exportCancelled = true
        s.exportProcess?.terminate()
    }

    func export() {
        guard let input = s.inputURL else { return }
        if s.outFormat == "Web" { exportWeb(input); return }
        let (crop, st, durSel) = cropTrim()

        let fmt = s.outFormat
        let ext = extFor(fmt)
        let nm = s.outName.isEmpty ? input.deletingPathExtension().lastPathComponent : s.outName

        // One-click: write straight into the chosen export folder, never overwriting.
        try? FileManager.default.createDirectory(at: s.exportFolder, withIntermediateDirectories: true)
        let out = uniqueOutputURL(s.exportFolder, nm, ext)

        let quality = s.quality, fpsOv = fpsOverride()
        let fast = s.fastExport && fastApplies(fmt)
        let burn = s.capBurn, wantSrt = s.capSrt, wantTxt = s.capTxt
        let wantCaps = burn || wantSrt || wantTxt
        let folder = s.exportFolder
        let outBase = out.deletingPathExtension().lastPathComponent
        let posLbl = isBatch ? " · clip \(s.queueIndex + 1)/\(s.queue.count)" : ""

        s.exporting = true
        s.exportProgress = 0; s.exportETA = ""
        s.setStatus(wantCaps ? "Transcribing…" : "Exporting \(fmt) · \(qLabel(quality))\(posLbl)…", "work")
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
                DispatchQueue.main.async { s.setStatus("Exporting \(fmt) · \(qLabel(quality))\(posLbl)…", "work") }
            }
            let p = plan(fmt, quality, crop, fpsOv, fast)
            let startT = Date()
            // -ss BEFORE -i: jump straight to the trim point (keyframe seek + precise
            // decode) instead of decoding the whole file and discarding frames — still
            // frame-accurate when re-encoding, much faster for trims deep into a clip.
            let res = runFFmpegProgress(["-y","-v","error","-progress","pipe:1","-ss",String(st),"-i",input.path,"-t",String(durSel),
                                         "-vf",p.vf] + args(p.codec) + [out.path], total: durSel,
                                        onStart: { proc in DispatchQueue.main.async { s.exportProcess = proc } }) { frac in
                let elapsed = Date().timeIntervalSince(startT)
                let eta = frac > 0.03 ? elapsed * (1 - frac) / frac : 0
                DispatchQueue.main.async { s.exportProgress = frac; s.exportETA = etaString(eta) }
            }
            // Embed a soft (toggleable) subtitle track for MP4 when requested.
            if res.code == 0, burn, ext == "mp4", let srt = burnSrt, FileManager.default.fileExists(atPath: out.path) {
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
                let cancelled = s.exportCancelled
                s.exporting = false; s.exportProgress = 0; s.exportETA = ""
                s.exportProcess = nil; s.exportCancelled = false
                if cancelled {
                    try? FileManager.default.removeItem(atPath: out.path)
                    s.setStatus("Export canceled.", "info")
                } else if res.code == 0, FileManager.default.fileExists(atPath: out.path) {
                    advanceAfterExport(out.lastPathComponent, out)
                } else {
                    // ffmpeg died mid-encode: remove the half-written file so a broken
                    // clip is never left where the "Saved" one should be.
                    try? FileManager.default.removeItem(atPath: out.path)
                    s.setStatus("Export failed: \(res.output.suffix(160))", "err")
                }
            }
        }
    }

    // "Harder estimate": encode short real samples at the actual export settings and
    // extrapolate to the full trim, then CALIBRATE the live model with the result
    // (factor = measured / model at the measured settings). Runs automatically on load
    // and on demand via the button; quiet — progress shows in the estimate card, not
    // the status bar. Cancel-safe: a stale result for a different clip is discarded.
    func hardEstimate() {
        guard let input = s.inputURL, !s.estimating, !s.exporting else { return }
        let (crop, st, durSel) = cropTrim()
        let measured = estParams()             // the settings the samples are encoded at
        let fmt = s.outFormat
        let tmp = NSTemporaryDirectory()
        let quality = s.quality, fpsOv = fpsOverride()
        let fast = s.fastExport && fastApplies(fmt)
        // Three short windows spread across the trim (20/50/80%) so one unusually quiet
        // or busy moment can't skew the estimate; short trims collapse to one window.
        let wd = 1.5
        let windows: [(start: Double, dur: Double)] = durSel <= 6
            ? [(st, min(4.0, max(0.5, durSel)))]
            : [0.2, 0.5, 0.8].map { (st + (durSel - wd) * $0, wd) }

        s.estimating = true
        DispatchQueue.global(qos: .userInitiated).async {
            // Encode the sample windows with the SAME plan() settings export will use.
            func sample(_ f: String) -> Double {
                let p = plan(f, quality, crop, fpsOv, fast)
                var bytes = 0.0, sampled = 0.0
                for (i, w) in windows.enumerated() {
                    let o = tmp + "scest_\(i)." + extFor(f)
                    _ = runTool(gFFmpeg, ["-y","-v","error","-ss",String(w.start),"-i",input.path,"-t",String(w.dur),
                                          "-vf",p.vf] + args(p.codec) + [o])
                    bytes += fileBytes(o); sampled += w.dur
                }
                return sampled > 0 ? bytes * durSel / sampled : 0   // extrapolate to the full trim
            }
            let bytes = fmt == "Web" ? sample("WEBM") + sample("GIF") : sample(fmt)
            DispatchQueue.main.async {
                s.estimating = false
                guard s.inputURL == input else { return }   // switched clips mid-measure
                s.calibBytes = max(0, bytes)
                s.calibParams = measured
                s.calibFormat = fmt
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

        let pw = plan("WEBM", s.quality, crop, fpsOverride(), s.fastExport)
        let pg = plan("GIF", s.quality, crop, fpsOverride())
        // -ss before -i (fast keyframe seek; see export()).
        let webmArgs = ["-y","-v","error","-progress","pipe:1","-ss",String(st),"-i",input.path,"-t",String(durSel),"-vf",pw.vf] + args(pw.codec) + [webm.path]
        let gifArgs = ["-y","-v","error","-progress","pipe:1","-ss",String(st),"-i",input.path,"-t",String(durSel),"-vf",pg.vf, gif.path]

        s.exporting = true
        s.exportProgress = 0; s.exportETA = ""
        s.setStatus("Exporting Web · \(qLabel(s.quality)) → \(base)_forweb…", "work")
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            func report(_ frac: Double, _ startT: Date) {
                let elapsed = Date().timeIntervalSince(startT)
                let eta = frac > 0.03 ? elapsed * (1 - frac) / frac : 0
                DispatchQueue.main.async { s.exportProgress = frac; s.exportETA = etaString(eta) }
            }
            let reg: (Process) -> Void = { proc in DispatchQueue.main.async { s.exportProcess = proc } }
            let t1 = Date()
            let e1 = runFFmpegProgress(webmArgs, total: durSel, onStart: reg) { report($0, t1) }
            var e2: (output: String, code: Int32) = ("", 0)
            if !s.exportCancelled {
                DispatchQueue.main.async { s.exportProgress = 0; s.exportETA = ""; s.setStatus("webm done, building gif…", "work") }
                let t2 = Date()
                e2 = runFFmpegProgress(gifArgs, total: durSel, onStart: reg) { report($0, t2) }
            }
            DispatchQueue.main.async {
                if s.exportCancelled {
                    try? FileManager.default.removeItem(at: folder)
                    s.exporting = false; s.exportProgress = 0; s.exportETA = ""
                    s.exportProcess = nil; s.exportCancelled = false
                    s.setStatus("Export canceled.", "info")
                    return
                }
                s.exporting = false; s.exportProgress = 0; s.exportETA = ""
                s.exportProcess = nil
                let okW = e1.code == 0 && FileManager.default.fileExists(atPath: webm.path)
                let okG = e2.code == 0 && FileManager.default.fileExists(atPath: gif.path)
                if okW && okG {
                    advanceAfterExport("\(base)_forweb/", folder)
                } else {
                    // Never leave a half-built bundle where a "Saved" one should be.
                    try? FileManager.default.removeItem(at: folder)
                    s.setStatus("Web export issue — webm:\(okW ? "ok" : "fail") gif:\(okG ? "ok" : "fail") \((e1.output + e2.output).suffix(140))", "err")
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

    // Wipe stashed imports plus leftover recordings/proxies/estimate samples on quit.
    func applicationWillTerminate(_ n: Notification) {
        let fm = FileManager.default
        try? fm.removeItem(at: gStashDir)
        if let items = try? fm.contentsOfDirectory(atPath: NSTemporaryDirectory()) {
            for f in items where f.hasPrefix("mbrec_") || f.hasPrefix("scpreview_")
                              || f.hasPrefix("scscrub_") || f.hasPrefix("scest_") {
                try? fm.removeItem(atPath: NSTemporaryDirectory() + f)
            }
        }
    }
}

// The build version, shown in the title bar (build.sh stamps it into Info.plist).
let gAppVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"

@main
struct ClipEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var state = EditorState()
    var body: some Scene {
        WindowGroup("SimpleClips — V \(gAppVersion)") { ContentView().environmentObject(state) }
            .windowResizability(.contentSize)
    }
}
