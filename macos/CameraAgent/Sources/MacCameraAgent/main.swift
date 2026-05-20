import AppKit
import AVFoundation
import CoreImage
import Darwin
import Foundation

let agentVersion = "mac-0.1.0"

let msgHello: UInt8 = 0x01
let frameCamera: UInt8 = 0x02
let frameHeartbeat: UInt8 = 0x03
let msgAuth: UInt8 = 0x04
let msgCamStatus: UInt8 = 0x05
let msgDeviceList: UInt8 = 0x07
let authOk: UInt8 = 0x20
let msgVersion: UInt8 = 0x32

let cmdStartCam: UInt8 = 0x10
let cmdStopCam: UInt8 = 0x11
let cmdSetQuality: UInt8 = 0x12
let cmdSelectCamera: UInt8 = 0x15
let cmdSetCameraCodec: UInt8 = 0x1B

let camOpening: UInt8 = 0x01
let camOk: UInt8 = 0x02
let camStopped: UInt8 = 0x03
let camFailed: UInt8 = 0x04
let camLost: UInt8 = 0x05

struct Config {
    var host = "sx1.jc116.com"
    var port = 9999
    var password = ""
    var reconnectSeconds = 10
    var cameraIndex = 0
    var quality = 100
    var fps = 15

    static func defaultPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/MacCameraAgent/config.ini"
    }

    static func load(path: String) -> Config {
        var cfg = Config()
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return cfg
        }
        var section = ""
        for line in raw.components(separatedBy: .newlines) {
            let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty || s.hasPrefix(";") || s.hasPrefix("#") { continue }
            if s.hasPrefix("[") && s.hasSuffix("]") {
                section = String(s.dropFirst().dropLast())
                continue
            }
            let parts = s.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count != 2 { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if section == "Server" {
                if key == "Host" { cfg.host = value }
                if key == "Port", let v = Int(value) { cfg.port = v }
                if key == "Password" { cfg.password = value }
                if key == "ReconnectSeconds", let v = Int(value) { cfg.reconnectSeconds = max(3, min(v, 300)) }
            } else if section == "Camera" {
                if key == "Index", let v = Int(value) { cfg.cameraIndex = max(0, v) }
                if key == "Quality", let v = Int(value) { cfg.quality = max(1, min(v, 100)) }
                if key == "Fps", let v = Int(value) { cfg.fps = max(1, min(v, 60)) }
            }
        }
        return cfg
    }
}

func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("[\(formatter.string(from: Date()))] \(message)")
    fflush(stdout)
}

final class TcpClient {
    private(set) var fd: Int32 = -1
    private let sendLock = NSLock()

    func connect(host: String, port: Int) -> Bool {
        close()

        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        if getaddrinfo(host, String(port), &hints, &result) != 0 {
            return false
        }
        defer { freeaddrinfo(result) }

        var ptr = result
        while ptr != nil {
            let ai = ptr!.pointee
            let s = socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol)
            if s >= 0 {
                if Darwin.connect(s, ai.ai_addr, ai.ai_addrlen) == 0 {
                    fd = s
                    return true
                }
                Darwin.close(s)
            }
            ptr = ai.ai_next
        }
        return false
    }

    func close() {
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
    }

    func sendFrame(type: UInt8, payload: [UInt8]) -> Bool {
        let size = UInt32(payload.count)
        var out: [UInt8] = [
            type,
            UInt8((size >> 24) & 0xff),
            UInt8((size >> 16) & 0xff),
            UInt8((size >> 8) & 0xff),
            UInt8(size & 0xff)
        ]
        out.append(contentsOf: payload)
        return sendAll(out)
    }

    func sendAll(_ bytes: [UInt8]) -> Bool {
        sendLock.lock()
        defer { sendLock.unlock() }
        if fd < 0 { return false }
        var sent = 0
        return bytes.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return false }
            while sent < bytes.count {
                let n = Darwin.send(fd, base.advanced(by: sent), bytes.count - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    func recvExact(_ count: Int) -> [UInt8]? {
        if fd < 0 { return nil }
        var data = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = data.withUnsafeMutableBytes { rawBuffer in
                Darwin.recv(fd, rawBuffer.baseAddress!.advanced(by: got), count - got, 0)
            }
            if n <= 0 { return nil }
            got += n
        }
        return data
    }
}

final class CameraStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let ciContext = CIContext()
    private let queue = DispatchQueue(label: "MacCameraAgent.camera")
    private var session: AVCaptureSession?
    private var lastFrame = Date.distantPast
    private var frameInterval = 1.0 / 15.0
    private var quality = 1.0
    private var lossless = false
    private var onFrame: (([UInt8]) -> Void)?

    static func cameraNames() -> [String] {
        discovery().devices.map { $0.localizedName }
    }

    private static func discovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
    }

    func requestPermission() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            let sem = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .video) { ok in
                granted = ok
                sem.signal()
            }
            sem.wait()
            return granted
        default:
            return false
        }
    }

    func start(index: Int, fps: Int, quality: Int, lossless: Bool, onFrame: @escaping ([UInt8]) -> Void) -> Bool {
        stop()
        guard requestPermission() else {
            log("Camera permission denied. Enable it in System Settings > Privacy & Security > Camera.")
            return false
        }

        let devices = Self.discovery().devices
        guard !devices.isEmpty else { return false }
        let device = devices[min(max(index, 0), devices.count - 1)]

        do {
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)

            let newSession = AVCaptureSession()
            newSession.sessionPreset = .high
            guard newSession.canAddInput(input), newSession.canAddOutput(output) else { return false }
            newSession.addInput(input)
            newSession.addOutput(output)

            self.frameInterval = 1.0 / Double(max(1, min(fps, 60)))
            self.quality = Double(max(1, min(quality, 100))) / 100.0
            self.lossless = lossless
            self.onFrame = onFrame
            self.session = newSession
            newSession.startRunning()
            log("Camera opened: \(device.localizedName)")
            return true
        } catch {
            log("Camera open failed: \(error.localizedDescription)")
            return false
        }
    }

    func stop() {
        if let session {
            session.stopRunning()
        }
        session = nil
        onFrame = nil
    }

    func updateQuality(_ q: Int) {
        quality = Double(max(1, min(q, 100))) / 100.0
    }

    func updateCodec(lossless: Bool) {
        self.lossless = lossless
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        if now.timeIntervalSince(lastFrame) < frameInterval { return }
        lastFrame = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let data: Data?
        if lossless {
            data = rep.representation(using: .png, properties: [:])
        } else {
            data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        }
        if let data {
            onFrame?([UInt8](data))
        }
    }
}

final class Agent {
    private var cfg: Config
    private let configPath: String
    private let client = TcpClient()
    private let camera = CameraStreamer()
    private var running = true
    private var connected = false
    private var cameraRunning = false
    private var selectedCamera: Int
    private var quality: Int
    private var lossless = false

    init(configPath: String) {
        self.configPath = configPath
        self.cfg = Config.load(path: configPath)
        self.selectedCamera = cfg.cameraIndex
        self.quality = cfg.quality
    }

    func run() {
        signal(SIGINT) { _ in exit(0) }
        signal(SIGTERM) { _ in exit(0) }

        while running {
            cfg = Config.load(path: configPath)
            selectedCamera = cfg.cameraIndex
            quality = cfg.quality

            log("Connecting to \(cfg.host):\(cfg.port) ...")
            if !client.connect(host: cfg.host, port: cfg.port) || !handshake() {
                client.close()
                log("Connect/auth failed, retry in \(cfg.reconnectSeconds)s")
                Thread.sleep(forTimeInterval: TimeInterval(cfg.reconnectSeconds))
                continue
            }

            connected = true
            log("Connected.")
            sendDeviceList()
            startHeartbeat()
            commandLoop()

            camera.stop()
            cameraRunning = false
            connected = false
            client.close()
            log("Disconnected, retry in \(cfg.reconnectSeconds)s")
            Thread.sleep(forTimeInterval: TimeInterval(cfg.reconnectSeconds))
        }
    }

    private func handshake() -> Bool {
        var name = Host.current().localizedName ?? Host.current().name ?? "MacCameraAgent"
        if name.count > 64 { name = String(name.prefix(64)) }
        guard client.sendFrame(type: msgHello, payload: Array(name.utf8)) else { return false }
        guard client.sendFrame(type: msgAuth, payload: Array(cfg.password.utf8)) else { return false }
        guard let resp = client.recvExact(1), resp[0] == authOk else {
            log("Authentication failed")
            return false
        }
        _ = client.sendFrame(type: msgVersion, payload: Array(agentVersion.utf8))
        return true
    }

    private func sendDeviceList() {
        let cams = CameraStreamer.cameraNames()
        var payload: [UInt8] = []
        appendList(cams, to: &payload)
        appendList([], to: &payload)
        _ = client.sendFrame(type: msgDeviceList, payload: payload)
    }

    private func appendList(_ items: [String], to payload: inout [UInt8]) {
        let count = min(items.count, 255)
        payload.append(UInt8(count))
        for item in items.prefix(count) {
            let bytes = Array(item.utf8.prefix(255))
            payload.append(UInt8(bytes.count))
            payload.append(contentsOf: bytes)
        }
    }

    private func startHeartbeat() {
        DispatchQueue.global().async { [weak self] in
            while let self, self.connected {
                Thread.sleep(forTimeInterval: 5)
                if !self.connected { break }
                if !self.client.sendFrame(type: frameHeartbeat, payload: []) {
                    self.connected = false
                    self.client.close()
                    break
                }
            }
        }
    }

    private func commandLoop() {
        while connected {
            guard let cmd = client.recvExact(1)?.first else { break }
            switch cmd {
            case cmdStartCam:
                startCamera()
            case cmdStopCam:
                stopCamera(status: camStopped)
            case cmdSetQuality:
                guard let q = client.recvExact(1)?.first else { connected = false; break }
                quality = Int(q)
                camera.updateQuality(quality)
            case cmdSelectCamera:
                guard let idx = client.recvExact(1)?.first else { connected = false; break }
                selectedCamera = Int(idx)
                if cameraRunning { stopCamera(status: camStopped) }
            case cmdSetCameraCodec:
                guard let codec = client.recvExact(1)?.first else { connected = false; break }
                lossless = (codec == 1)
                camera.updateCodec(lossless: lossless)
            default:
                log("Ignored unsupported command: 0x\(String(cmd, radix: 16))")
            }
        }
        connected = false
    }

    private func startCamera() {
        if cameraRunning { return }
        _ = client.sendFrame(type: msgCamStatus, payload: [camOpening])
        let ok = camera.start(index: selectedCamera, fps: cfg.fps, quality: quality, lossless: lossless) { [weak self] bytes in
            guard let self, self.connected else { return }
            if !self.client.sendFrame(type: frameCamera, payload: bytes) {
                self.connected = false
                self.client.close()
            }
        }
        if ok {
            cameraRunning = true
            _ = client.sendFrame(type: msgCamStatus, payload: [camOk])
        } else {
            cameraRunning = false
            _ = client.sendFrame(type: msgCamStatus, payload: [camFailed])
        }
    }

    private func stopCamera(status: UInt8) {
        camera.stop()
        cameraRunning = false
        _ = client.sendFrame(type: msgCamStatus, payload: [status])
    }
}

var configPath = Config.defaultPath()
let args = CommandLine.arguments
for i in 0..<args.count {
    if args[i] == "--config", i + 1 < args.count {
        configPath = args[i + 1]
    }
}

log("MacCameraAgent \(agentVersion)")
log("Config: \(configPath)")
Agent(configPath: configPath).run()
