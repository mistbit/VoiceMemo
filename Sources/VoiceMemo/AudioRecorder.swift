import Foundation
@preconcurrency import ScreenCaptureKit
import AVFoundation
import AppKit

@available(macOS 13.0, *)
class AudioRecorder: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    @Published var isRecording = false
    @Published var statusMessage = "Ready to record"
    @Published var availableApps: [SCRunningApplication] = []
    @Published var selectedApp: SCRunningApplication?
    @Published var latestTask: MeetingTask?
    @Published var recordingDuration: TimeInterval = 0
    
    var lastUploadedURL: URL? {
        if let urlStr = latestTask?.ossUrl {
            return URL(string: urlStr)
        }
        return nil
    }
    
    private var notificationObserver: NSObjectProtocol?
    private var timer: Timer?
    
    private var settings: SettingsStore
    private var recordingId: String?
    private var recordingStartTime: Date?
    private var currentSaveLocation: URL?
    
    // System Audio (Remote)
    private var stream: SCStream?
    private var remoteAssetWriter: AVAssetWriter?
    private var remoteAssetWriterInput: AVAssetWriterInput?
    private let remoteQueue = DispatchQueue(label: "cn.mistbit.voicememo.remote")
    private var isFirstRemoteBuffer = true
    private var remoteURL: URL?
    
    // Microphone Audio (Local)
    private var micEngine: AVAudioEngine?
    private var micFile: AVAudioFile?
    private var micInputFormat: AVAudioFormat?
    private let micQueue = DispatchQueue(label: "cn.mistbit.voicememo.mic")
    private var micTapInstalled = false
    private var localURL: URL?
    
    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
        
        // Listen for task updates to refresh latestTask
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .meetingTaskDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let taskId = notification.object as? UUID,
               let currentTask = self.latestTask,
               currentTask.id == taskId,
               let updatedTask = notification.userInfo?[MeetingTask.userInfoTaskKey] as? MeetingTask {
                self.latestTask = updatedTask
            }
        }
        
        Task {
            await refreshAvailableApps()
        }
    }
    
    @MainActor
    func refreshAvailableApps() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            self.availableApps = content.applications
                .filter { !$0.applicationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted { $0.applicationName < $1.applicationName }
            
            if let wechat = self.availableApps.first(where: { $0.applicationName.lowercased().contains("wechat") || $0.applicationName.contains("微信") }) {
                self.selectedApp = wechat
                self.statusMessage = "Auto-selected: \(wechat.applicationName)"
            }
        } catch {
            self.statusMessage = "Failed to load apps: \(error.localizedDescription)"
        }
    }

    private var recordingMode: SettingsStore.RecordingMode {
        settings.recordingMode
    }

    private var usesSystemAudio: Bool {
        recordingMode != .localOnly
    }

    private var usesMicrophone: Bool {
        recordingMode != .remoteOnly
    }
    
    @MainActor
    func startRecording() {
        NotificationCenter.default.post(name: .playbackShouldStop, object: nil)
        var appName = "Local Only"
        var appProcessID: pid_t = 0
        if usesSystemAudio {
            guard let app = selectedApp else {
                statusMessage = "Please select an app first"
                return
            }
            appName = app.applicationName
            appProcessID = app.processID
        }
        
        statusMessage = "Requesting permissions..."
        settings.log("Start recording: app=\(appName) mode=\(recordingMode.rawValue)")
        
        if usesMicrophone {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                beginRecordingSession(appName: appName, appProcessID: appProcessID)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    if granted {
                        Task { @MainActor in
                            self.beginRecordingSession(appName: appName, appProcessID: appProcessID)
                        }
                    } else {
                        Task { @MainActor in
                            self.statusMessage = "Microphone permission denied"
                        }
                    }
                }
            case .denied, .restricted:
                statusMessage = "Microphone permission denied"
                return
            @unknown default:
                return
            }
        } else {
            beginRecordingSession(appName: appName, appProcessID: appProcessID)
        }
    }
    
    private func beginRecordingSession(appName: String, appProcessID: pid_t) {
        isFirstRemoteBuffer = true
        self.recordingStartTime = Date()
        self.recordingDuration = 0
        
        DispatchQueue.main.async {
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self = self, let startTime = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(startTime)
            }
        }
        
        // Generate URLs
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let dateStr = formatter.string(from: Date())
        
        // Create Recording ID (Timestamp + Random)
        let uuid = UUID().uuidString.prefix(8)
        self.recordingId = "\(dateStr)-\(uuid)"
        
        let folder = settings.getSavePath()
        if folder.startAccessingSecurityScopedResource() {
            self.currentSaveLocation = folder
        }
        
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        
        switch recordingMode {
        case .mixed:
            self.remoteURL = folder.appendingPathComponent("recording-\(dateStr)-remote.m4a")
            self.localURL = folder.appendingPathComponent("recording-\(dateStr)-local.m4a")
            if let recordingId, let remoteURL, let localURL {
                settings.log("Recording session: id=\(recordingId) remote=\(remoteURL.path) local=\(localURL.path)")
            }
            startSystemAudioCapture(appName: appName, appProcessID: appProcessID)
            startMicrophoneCapture()
        case .remoteOnly:
            self.remoteURL = folder.appendingPathComponent("recording-\(dateStr)-remote.m4a")
            self.localURL = nil
            if let recordingId, let remoteURL {
                settings.log("Recording session: id=\(recordingId) remote=\(remoteURL.path)")
            }
            startSystemAudioCapture(appName: appName, appProcessID: appProcessID)
        case .localOnly:
            self.remoteURL = nil
            self.localURL = folder.appendingPathComponent("recording-\(dateStr)-local.m4a")
            if let recordingId, let localURL {
                settings.log("Recording session: id=\(recordingId) local=\(localURL.path)")
            }
            startMicrophoneCapture()
        }
        
        DispatchQueue.main.async {
            self.isRecording = true
            switch self.recordingMode {
            case .mixed:
                self.statusMessage = "Recording (Remote + Local)..."
            case .remoteOnly:
                self.statusMessage = "Recording (Remote Only)..."
            case .localOnly:
                self.statusMessage = "Recording (Local Only)..."
            }
        }
    }
    
    // MARK: - System Audio (SCK)
    
    private func startSystemAudioCapture(appName: String, appProcessID: pid_t) {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let matchedApp = content.applications.first(where: { $0.processID == appProcessID }) else {
                    settings.log("SCK start error: target app not found \(appName) \(appProcessID)")
                    return
                }
                
                let filter = SCContentFilter(display: content.displays.first!, including: [matchedApp], exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.sampleRate = 48000
                config.channelCount = 2
                config.excludesCurrentProcessAudio = true
                config.width = 2
                config.height = 2
                
                stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: remoteQueue)
                try await stream?.startCapture()
            } catch {
                settings.log("SCK start error: \(error.localizedDescription)")
            }
        }
    }
    
    private func setupRemoteWriter(for sampleBuffer: CMSampleBuffer) {
        guard let url = remoteURL,
              let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }
        
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            
            remoteAssetWriter = try AVAssetWriter(outputURL: url, fileType: .m4a)
            
            let sampleRate = streamDesc.pointee.mSampleRate
            let channels = Int(streamDesc.pointee.mChannelsPerFrame)
            
            self.settings.log("Setup remote writer: rate=\(sampleRate), channels=\(channels)")
            
            if sampleRate <= 0 || channels <= 0 {
                self.settings.log("Invalid audio format: rate or channels is 0")
                return
            }

            // AAC encoder is picky. 44100 or 48000 are best.
            // We use the source rate if it's common, otherwise default to 48000.
            let targetSampleRate: Double
            if sampleRate == 44100 || sampleRate == 48000 || sampleRate == 32000 || sampleRate == 24000 || sampleRate == 16000 {
                targetSampleRate = sampleRate
            } else {
                targetSampleRate = 48000
                self.settings.log("Non-standard sample rate \(sampleRate), using 48000 for AAC")
            }

            let audioSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: targetSampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 128000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            
            remoteAssetWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: formatDesc)
            remoteAssetWriterInput?.expectsMediaDataInRealTime = true
            
            if let writer = remoteAssetWriter, let input = remoteAssetWriterInput, writer.canAdd(input) {
                writer.add(input)
                if writer.startWriting() {
                    writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                    self.settings.log("Remote writer started successfully at rate \(targetSampleRate)")
                } else {
                    self.settings.log("Remote writer failed to startWriting: \(String(describing: writer.error))")
                }
            } else {
                self.settings.log("Remote writer cannot add input")
            }
        } catch {
            settings.log("Remote writer error: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Microphone Audio (AVAudioEngine)
    
    private func startMicrophoneCapture() {
        micQueue.async {
            guard let url = self.localURL else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            
            let audioSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: inputFormat.sampleRate,
                AVNumberOfChannelsKey: Int(inputFormat.channelCount),
                AVEncoderBitRateKey: 128000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            
            do {
                let file = try AVAudioFile(forWriting: url, settings: audioSettings)
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                    do {
                        try file.write(from: buffer)
                    } catch {
                        self?.settings.log("Mic write error: \(error.localizedDescription)")
                    }
                }
                self.micTapInstalled = true
                engine.prepare()
                try engine.start()
                
                self.micEngine = engine
                self.micFile = file
                self.micInputFormat = inputFormat
                self.settings.log("Mic engine started: rate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)")
            } catch {
                self.settings.log("Mic engine start error: \(error.localizedDescription)")
            }
        }
    }
    
    private func stopMicrophoneCapture() async {
        await withCheckedContinuation { continuation in
            micQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }
                
                if let engine = self.micEngine {
                    if self.micTapInstalled {
                        engine.inputNode.removeTap(onBus: 0)
                        self.micTapInstalled = false
                    }
                    if engine.isRunning {
                        engine.stop()
                    }
                }
                self.micEngine = nil
                self.micFile = nil
                self.micInputFormat = nil
                continuation.resume()
            }
        }
    }
    
    // MARK: - Stop & Merge
    
    @MainActor
    func stopRecording() {
        Task {
            await MainActor.run {
                self.timer?.invalidate()
                self.timer = nil
            }
            
            settings.log("Stop recording")
            // 1. Stop System Audio
            try? await stream?.stopCapture()
            stream = nil
            if let writer = remoteAssetWriter {
                if writer.status == .writing {
                    remoteAssetWriterInput?.markAsFinished()
                    await writer.finishWriting()
                    settings.log("Remote writer finished. Final status: \(writer.status.rawValue)")
                } else {
                    settings.log("Remote writer was not writing. Status: \(writer.status.rawValue), Error: \(String(describing: writer.error))")
                }
            }
            
            // 2. Stop Microphone
            await stopMicrophoneCapture()
            
            // 3. Merge
            if let rURL = remoteURL, let lURL = localURL {
                settings.log("Merge start: remote=\(rURL.path) local=\(lURL.path)")
                await MainActor.run { self.statusMessage = "Merging audio files..." }
                let mixedURL = rURL.deletingLastPathComponent().appendingPathComponent(rURL.lastPathComponent.replacingOccurrences(of: "remote", with: "mixed"))
                do {
                    try await mergeAudioFiles(audio1: rURL, audio2: lURL, output: mixedURL)
                    await MainActor.run {
                        self.isRecording = false
                        self.statusMessage = "Saved to \(mixedURL.deletingLastPathComponent().lastPathComponent)"
                        
                        if let recId = self.recordingId {
                            let formatter = DateFormatter()
                            formatter.dateFormat = "MM-dd HH:mm"
                            let dateStr = formatter.string(from: self.recordingStartTime ?? Date())
                            let title = "Rec \(dateStr)"
                            let task = MeetingTask(recordingId: recId, localFilePath: mixedURL.path, title: title)
                            Task { try? await StorageManager.shared.currentProvider.saveTask(task) }
                            self.latestTask = task
                        }
                    }
                    settings.log("Merge success: mixed=\(mixedURL.path)")
                } catch {
                    await MainActor.run {
                        self.isRecording = false
                        self.statusMessage = "Merge failed: \(error.localizedDescription)"
                    }
                    settings.log("Merge failed: \(error.localizedDescription)")
                }
            } else if let finalURL = remoteURL ?? localURL {
                await MainActor.run {
                    self.isRecording = false
                    self.statusMessage = "Saved to \(finalURL.deletingLastPathComponent().lastPathComponent)"
                    
                    if let recId = self.recordingId {
                        let formatter = DateFormatter()
                        formatter.dateFormat = "MM-dd HH:mm"
                        let dateStr = formatter.string(from: self.recordingStartTime ?? Date())
                        let title = "Rec \(dateStr)"
                        let task = MeetingTask(recordingId: recId, localFilePath: finalURL.path, title: title)
                        Task { try? await StorageManager.shared.currentProvider.saveTask(task) }
                        self.latestTask = task
                    }
                }
                settings.log("Recording saved: url=\(finalURL.path)")
            } else {
                await MainActor.run {
                    self.isRecording = false
                    self.statusMessage = "No audio captured"
                }
            }
            
            // Cleanup
            if let loc = self.currentSaveLocation {
                loc.stopAccessingSecurityScopedResource()
                self.currentSaveLocation = nil
            }
            
            remoteAssetWriter = nil
            remoteAssetWriterInput = nil
        }
    }

    
    private func mergeAudioFiles(audio1: URL, audio2: URL, output: URL) async throws {
        let composition = AVMutableComposition()
        
        let asset1 = AVURLAsset(url: audio1)
        let asset2 = AVURLAsset(url: audio2)
        
        var hasTrack1 = false
        var hasTrack2 = false
        
        do {
            if let tracks1 = try? await asset1.loadTracks(withMediaType: .audio), let sourceTrack1 = tracks1.first {
                let track1 = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                let duration = try await asset1.load(.duration)
                try track1?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceTrack1, at: .zero)
                hasTrack1 = true
            }
        } catch {
            settings.log("Warning: Could not load track 1: \(error.localizedDescription)")
        }
        
        do {
            if let tracks2 = try? await asset2.loadTracks(withMediaType: .audio), let sourceTrack2 = tracks2.first {
                let track2 = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                let duration = try await asset2.load(.duration)
                try track2?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceTrack2, at: .zero)
                hasTrack2 = true
            }
        } catch {
            settings.log("Warning: Could not load track 2: \(error.localizedDescription)")
        }
        
        guard hasTrack1 || hasTrack2 else {
            throw NSError(domain: "AudioRecorder", code: 404, userInfo: [NSLocalizedDescriptionKey: "No valid audio tracks found to merge"])
        }
        
        if FileManager.default.fileExists(atPath: output.path) {
            try? FileManager.default.removeItem(at: output)
        }
        
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "AudioRecorder", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }
        
        export.outputURL = output
        export.outputFileType = .m4a
        await export.export()
        
        if let error = export.error {
            throw error
        }
    }
    
    // MARK: - Delegates
    
    // SCStreamDelegate
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        
        if isFirstRemoteBuffer {
            setupRemoteWriter(for: sampleBuffer)
            isFirstRemoteBuffer = false
        }
        if let input = remoteAssetWriterInput, input.isReadyForMoreMediaData {
            if !input.append(sampleBuffer) {
                settings.log("Remote append error: \(String(describing: remoteAssetWriter?.error))")
            }
        }
    }
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        settings.log("SCStream error: \(error.localizedDescription)")
    }
    
}

@available(macOS 13.0, *)
class AudioPlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var playingTaskId: UUID?
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var lastErrorMessage: String?
    
    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    private var stopPlaybackObserver: NSObjectProtocol?

    override init() {
        super.init()
        stopPlaybackObserver = NotificationCenter.default.addObserver(
            forName: .playbackShouldStop,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stop()
            }
        }
    }

    deinit {
        if let observer = stopPlaybackObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        timer?.invalidate()
        timer = nil
    }

    @MainActor
    func toggle(task: MeetingTask) {
        if playingTaskId == task.id {
            if isPlaying {
                pause()
            } else {
                resume()
            }
        } else {
            play(filePath: task.localFilePath, taskId: task.id)
        }
    }

    @MainActor
    func play(filePath: String, taskId: UUID?) {
        guard FileManager.default.fileExists(atPath: filePath) else {
            lastErrorMessage = "Audio file not found"
            stop()
            return
        }
        stop() // Stop previous
        
        let url = URL(fileURLWithPath: filePath)
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            
            audioPlayer = player
            duration = player.duration
            isPlaying = true
            playingTaskId = taskId
            lastErrorMessage = nil
            
            startTimer()
        } catch {
            lastErrorMessage = error.localizedDescription
            stop()
        }
    }
    
    @MainActor
    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopTimer()
    }
    
    @MainActor
    func resume() {
        if let player = audioPlayer {
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    @MainActor
    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        playingTaskId = nil
        currentTime = 0
        duration = 0
        stopTimer()
    }
    
    @MainActor
    func seek(to time: TimeInterval) {
        guard let player = audioPlayer else { return }
        player.currentTime = time
        currentTime = time
    }
    
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let player = self.audioPlayer else { return }
                self.currentTime = player.currentTime
            }
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            isPlaying = false
            playingTaskId = nil
            currentTime = 0
            stopTimer()
        }
    }
}
