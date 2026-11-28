import AVFoundation
import CoreLocation
import LocalAuthentication
import Network
import Security
import UserNotifications
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Capabilities {
    func addStandard() {
        add("app.info") { _ in
            let info = Bundle.main.infoDictionary ?? [:]
            return ["id": Bundle.main.bundleIdentifier ?? "", "version": info["CFBundleShortVersionString"] as? String ?? "", "build": info["CFBundleVersion"] as? String ?? ""]
        }
        add("device.info") { _ in
            let os = ProcessInfo.processInfo.operatingSystemVersion
            #if os(iOS)
            let (system, kind) = ("ios", UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone")
            #else
            let (system, kind) = ("macos", "mac")
            #endif
            return ["system": system, "kind": kind, "version": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                    "locale": Locale.current.identifier, "timeZone": TimeZone.current.identifier, "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled]
        }
        add("network.status") { _ in await Network.status() }
        add("haptics.play") { arguments in
            Haptics.play(arguments["style"] ?? "success")
            return [:]
        }
        add("clipboard.write") { arguments in
            let text = arguments["text"] ?? ""
            #if os(iOS)
            UIPasteboard.general.string = text
            #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #endif
            return [:]
        }
        add("speech.speak") { arguments in
            Sound.shared.speak(arguments["text"] ?? "", language: arguments["language"])
            return [:]
        }
        add("speech.stop") { _ in Sound.shared.hush(); return [:] }
        add("audio.play") { arguments in
            guard let url = URL(string: arguments["url"] ?? ""), ["https", "http"].contains(url.scheme ?? "") else { throw Failure("audio.play needs a url") }
            Sound.shared.play(url, loop: arguments["loop"] == "true")
            return [:]
        }
        add("audio.pause") { _ in Sound.shared.player?.pause(); return [:] }
        add("audio.resume") { _ in Sound.shared.player?.play(); return [:] }
        add("audio.stop") { _ in Sound.shared.stop(); return [:] }
        add("audio.seek") { arguments in
            await Sound.shared.player?.seek(to: CMTime(seconds: Double(arguments["seconds"] ?? "") ?? 0, preferredTimescale: 600))
            return [:]
        }
        add("audio.status") { _ in Sound.shared.status }
        #if os(iOS)
        add("battery.status") { _ in
            UIDevice.current.isBatteryMonitoringEnabled = true
            return ["level": Double(UIDevice.current.batteryLevel), "charging": [.charging, .full].contains(UIDevice.current.batteryState)]
        }
        add("screen.keepAwake") { arguments in
            UIApplication.shared.isIdleTimerDisabled = arguments["on"] != "false"
            return [:]
        }
        add("app.settings") { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
            return [:]
        }
        add("torch.set") { arguments in
            guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { throw Failure("This device has no torch") }
            try device.lockForConfiguration()
            device.torchMode = arguments["on"] == "true" ? .on : .off
            device.unlockForConfiguration()
            return [:]
        }
        #endif
    }

    func addGroup(_ group: Group) {
        switch group {
        case .clipboardReading:
            add("clipboard.read") { _ in
                #if os(iOS)
                ["text": UIPasteboard.general.string ?? ""]
                #else
                ["text": NSPasteboard.general.string(forType: .string) ?? ""]
                #endif
            }
        case .biometrics:
            add("biometrics.check") { arguments in
                let context = LAContext()
                var problem: NSError?
                guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else { throw Failure(problem?.localizedDescription ?? "Not available") }
                return ["passed": try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: arguments["reason"] ?? "Confirm it is you")]
            }
        case .keychain:
            add("keychain.set") { try Keychain.set(Self.named($0), $0["value"] ?? ""); return [:] }
            add("keychain.get") { Keychain.get(try Self.named($0)).map { ["value": $0] } ?? [:] }
            add("keychain.delete") { try Keychain.delete(Self.named($0)); return [:] }
        case .location:
            add("location.current") { _ in
                let place = try await Locator().current()
                return ["latitude": place.coordinate.latitude, "longitude": place.coordinate.longitude, "accuracy": place.horizontalAccuracy]
            }
        case .notifications:
            add("notifications.request") { _ in
                ["allowed": try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])]
            }
            add("notifications.schedule") { arguments in
                let content = UNMutableNotificationContent()
                content.title = arguments["title"] ?? ""
                content.body = arguments["body"] ?? ""
                content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, Double(arguments["seconds"] ?? "") ?? 1), repeats: false)
                let id = arguments["id"] ?? UUID().uuidString
                try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                return ["id": id]
            }
            add("notifications.cancel") { arguments in
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [arguments["id"] ?? ""])
                return [:]
            }
        case .recording:
            add("audio.record") { _ in try await Sound.shared.record(); return [:] }
            add("audio.finish") { _ in
                guard let file = Sound.shared.finish() else { throw Failure("Nothing is being recorded") }
                return ["data": try Data(contentsOf: file).base64EncodedString(), "type": "audio/mp4"]
            }
        }
    }

    private static func named(_ arguments: Arguments) throws -> String {
        guard let name = arguments["name"], !name.isEmpty else { throw Failure("Give a name") }
        return name
    }
}

enum Haptics {
    @MainActor static func play(_ style: String) {
        #if os(iOS)
        switch style {
        case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "selection": UISelectionFeedbackGenerator().selectionChanged()
        case "light": UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case "medium": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case "heavy": UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        default: UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        #endif
    }
}

private enum Network {
    static func status() async -> [String: Any] {
        let monitor = NWPathMonitor()
        for await path in monitor {
            let kind = path.usesInterfaceType(.wifi) ? "wifi" : path.usesInterfaceType(.cellular) ? "cellular" : "other"
            return ["online": path.status == .satisfied, "kind": kind, "expensive": path.isExpensive]
        }
        return ["online": false]
    }
}

/// What the app plays, says and records.
@MainActor
private final class Sound {
    static let shared = Sound()
    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private let voice = AVSpeechSynthesizer()
    private var recorder: AVAudioRecorder?

    func play(_ url: URL, loop: Bool) {
        stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let item = AVPlayerItem(url: url)
        let player = loop ? AVQueuePlayer() : AVQueuePlayer(playerItem: item)
        if loop { looper = AVPlayerLooper(player: player, templateItem: item) }
        self.player = player
        player.play()
    }

    func stop() {
        player?.pause()
        looper = nil
        player = nil
    }

    var status: [String: Any] {
        let seconds = player?.currentTime().seconds ?? 0, length = player?.currentItem?.duration.seconds ?? 0
        return ["playing": player?.timeControlStatus == .playing, "seconds": seconds.isFinite ? seconds : 0, "length": length.isFinite ? length : 0]
    }

    func speak(_ text: String, language: String?) {
        let said = AVSpeechUtterance(string: text)
        if let language { said.voice = AVSpeechSynthesisVoice(language: language) }
        voice.speak(said)
    }

    func hush() { voice.stopSpeaking(at: .immediate) }

    func record() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Capabilities.Failure("The microphone is not allowed") }
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: .defaultToSpeaker)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        let file = FileManager.default.temporaryDirectory.appending(path: "recording-\(UUID().uuidString).m4a")
        let recorder = try AVAudioRecorder(url: file, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
        guard recorder.record() else { throw Capabilities.Failure("Could not record") }
        self.recorder = recorder
    }

    func finish() -> URL? {
        defer { recorder = nil }
        recorder?.stop()
        return recorder?.url
    }
}

private enum Keychain {
    // A service of its own, so that a page cannot read what the app keeps.
    private static func query(_ name: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "instant-record-capabilities", kSecAttrAccount: name]
    }

    static func set(_ name: String, _ value: String) throws {
        SecItemDelete(query(name) as CFDictionary)
        var item = query(name)
        item[kSecValueData] = Data(value.utf8)
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Capabilities.Failure("The keychain answered \(status)") }
    }

    static func get(_ name: String) -> String? {
        var item = query(name)
        item[kSecReturnData] = true
        var found: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &found) == errSecSuccess else { return nil }
        return (found as? Data).map { String(decoding: $0, as: UTF8.self) }
    }

    static func delete(_ name: String) throws {
        let status = SecItemDelete(query(name) as CFDictionary)
        guard [errSecSuccess, errSecItemNotFound].contains(status) else { throw Capabilities.Failure("The keychain answered \(status)") }
    }
}

/// Where the device is, once. It keeps itself until it has an answer.
@MainActor
private final class Locator: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var answer: CheckedContinuation<CLLocation, Error>?
    private var kept: Locator?

    func current() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { answer in
            self.answer = answer
            kept = self
            manager.delegate = self
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() } else { begin() }
        }
    }

    private func begin() {
        switch manager.authorizationStatus {
        case .notDetermined: break
        case .denied, .restricted: end(.failure(Capabilities.Failure("Location is not allowed")))
        default: manager.requestLocation()
        }
    }

    private func end(_ result: Result<CLLocation, Error>) {
        answer?.resume(with: result)
        answer = nil
        kept = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { if answer != nil { begin() } }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations places: [CLLocation]) { if let last = places.last { end(.success(last)) } }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { end(.failure(error)) }
}
