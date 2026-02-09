import Foundation
import WhisperKit
import AVFoundation

class LocalWhisperService: TranscriptionService {
    private let settings: SettingsStore
    
    init(settings: SettingsStore) {
        self.settings = settings
    }
    
    func createTask(fileUrl: String) async throws -> String {
        guard let url = URL(string: fileUrl), url.isFileURL else {
            let fileURL = URL(fileURLWithPath: fileUrl)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                 return try await startTask(url: fileURL)
            }
            throw TranscriptionError.invalidURL(fileUrl)
        }
        return try await startTask(url: url)
    }
    
    private func startTask(url: URL) async throws -> String {
        let modelName = settings.whisperModel
        
        // Ensure model is loaded or ready to load
        // Note: Actual loading happens inside the task to avoid blocking UI if possible,
        // but here we might want to fail fast. 
        // For now, we assume ModelManager handles loading concurrency.
        
        let taskId = UUID().uuidString
        
        // Create a detached task to allow cancellation
        let enableRoleSplit = settings.enableRoleSplit
        let task = Task {
            await LocalTaskManager.shared.executeTask(taskId: taskId, audioUrl: url, modelName: modelName, enableRoleSplit: enableRoleSplit)
        }
        
        await LocalTaskManager.shared.registerTask(taskId, task: task)
        
        return taskId
    }
    
    func getTaskInfo(taskId: String) async throws -> (status: String, result: [String: Any]?) {
        return await LocalTaskManager.shared.getTaskStatus(taskId)
    }
    
    func fetchJSON(url: String) async throws -> [String: Any] {
        if let u = URL(string: url), u.isFileURL {
            let data = try Data(contentsOf: u)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
            }
            throw TranscriptionError.parseError("Invalid JSON in local file")
        }
        guard let u = URL(string: url) else { throw TranscriptionError.invalidURL(url) }
        let (data, _) = try await URLSession.shared.data(from: u)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}

// MARK: - Task Manager

actor LocalTaskManager {
    static let shared = LocalTaskManager()
    
    enum TaskStatus {
        case running([String: Any]?)
        case success([String: Any])
        case failed(String)
        case cancelled
    }
    
    struct TaskHandle {
        let task: Task<Void, Never>
        let priority: Int // For memory management
        let startTime: Date
    }
    
    private var tasks: [String: TaskStatus] = [:]
    private var activeTasks: [String: TaskHandle] = [:]
    
    func registerTask(_ id: String, task: Task<Void, Never>) {
        tasks[id] = .running(nil)
        activeTasks[id] = TaskHandle(task: task, priority: 1, startTime: Date())
    }
    
    func updateTask(_ id: String, status: TaskStatus) {
        tasks[id] = status
        if case .success = status {
            activeTasks.removeValue(forKey: id)
        } else if case .failed = status {
            activeTasks.removeValue(forKey: id)
        } else if case .cancelled = status {
            activeTasks.removeValue(forKey: id)
        }
    }
    
    func updatePartial(_ id: String, result: [String: Any]) {
        tasks[id] = .running(result)
    }
    
    func getTaskStatus(_ id: String) -> (String, [String: Any]?) {
        guard let status = tasks[id] else {
            return ("FAILED", ["error": "Task not found"])
        }
        switch status {
        case .running(let data):
            return ("RUNNING", data)
        case .success(let result):
            return ("SUCCESS", result)
        case .failed(let error):
            return ("FAILED", ["error": error])
        case .cancelled:
            return ("FAILED", ["error": "Task cancelled"])
        }
    }
    
    func cancelTask(_ id: String) {
        if let handle = activeTasks[id] {
            handle.task.cancel()
            updateTask(id, status: .cancelled)
        }
    }
    
    // Memory Pressure Handling
    func handleMemoryWarning() {
        // Simple strategy: cancel oldest running tasks or lower priority ones
        // Here we just print, but in production we might cancel tasks
        print("[LocalTaskManager] Received memory warning. Checking active tasks...")
        
        WhisperModelManager.shared.releaseCachedModels()
    }
    
    // MARK: - Execution Logic
    
    func executeTask(taskId: String, audioUrl: URL, modelName: String, enableRoleSplit: Bool) async {
        do {
            // Check cancellation
            try Task.checkCancellation()
            
            // Check settings for debug
            // Accessing SettingsStore via dependency or pass it in. 
            // Since LocalTaskManager is a singleton, it should probably read user defaults or be configured.
            // For simplicity, we read UserDefaults directly or assume we can access SettingsStore.
            // But SettingsStore is an ObservableObject.
            // Let's rely on standard UserDefaults for these debug flags inside the Actor if needed,
            // or pass them in arguments.
            let debugSaveAudio = UserDefaults.standard.bool(forKey: "debugSaveIntermediateAudio")
            let debugExportRaw = UserDefaults.standard.bool(forKey: "debugExportRawResults")
            let debugLogTime = UserDefaults.standard.bool(forKey: "debugLogModelTime")
            
            let startTime = Date()
            
            // 1. Preprocess Audio
            let processedUrl = try await preprocessAudio(audioUrl)
            
            if debugSaveAudio {
                let tempDir = FileManager.default.temporaryDirectory
                let debugPath = tempDir.appendingPathComponent("debug_processed_\(taskId).wav")
                try? FileManager.default.copyItem(at: processedUrl, to: debugPath)
                print("[Debug] Saved processed audio to: \(debugPath.path)")
            }
            
            // 2. Load Model
            let loadStart = Date()
            try await WhisperModelManager.shared.loadModel(modelName)
            if debugLogTime {
                print("[Debug] Model load time: \(Date().timeIntervalSince(loadStart))s")
            }
            
            // 3. Run Parallel Inference (ASR + Diarization)
            let inferenceStart = Date()
            let result = try await runParallelInference(audioPath: processedUrl.path, taskId: taskId, modelManager: WhisperModelManager.shared, debugExport: debugExportRaw, enableRoleSplit: enableRoleSplit)
            if debugLogTime {
                print("[Debug] Inference time: \(Date().timeIntervalSince(inferenceStart))s")
            }
            
            // 4. Format Output
            let output = formatOutput(result)
            
            if debugLogTime {
                print("[Debug] Total task time: \(Date().timeIntervalSince(startTime))s")
            }
            
            updateTask(taskId, status: .success(output))
            
            // Cleanup processed audio if it's a temp file
            if processedUrl != audioUrl {
                try? FileManager.default.removeItem(at: processedUrl)
            }
            
        } catch {
            if error is CancellationError {
                print("Task \(taskId) cancelled")
                updateTask(taskId, status: .cancelled)
            } else {
                print("Task \(taskId) failed: \(error)")
                updateTask(taskId, status: .failed(error.localizedDescription))
            }
        }
    }
    
    private func preprocessAudio(_ url: URL) async throws -> URL {
        let audioFile = try AVAudioFile(forReading: url)
        
        try validateAudioFile(audioFile)
        
        let format = audioFile.processingFormat
        if format.sampleRate == 16000 && format.channelCount == 1 {
            return url
        }
        
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let outputUrl = FileManager.default.temporaryDirectory.appendingPathComponent("localwhisper_\(UUID().uuidString).wav")
        let outputFile = try AVAudioFile(forWriting: outputUrl, settings: outputFormat.settings)
        guard let converter = AVAudioConverter(from: audioFile.processingFormat, to: outputFormat) else {
            throw InferenceError.processingFailed
        }
        
        final class EndFlag: @unchecked Sendable {
            var value: Bool = false
        }
        let endFlag = EndFlag()
        let inputFrameCapacity: AVAudioFrameCount = 4096
        let outputFrameCapacity: AVAudioFrameCount = 4096
        
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if endFlag.value {
                outStatus.pointee = .endOfStream
                return nil
            }
            
            let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: inputFrameCapacity)!
            do {
                let remainingFrames = audioFile.length - audioFile.framePosition
                let remaining = AVAudioFrameCount(max(AVAudioFramePosition(0), remainingFrames))
                let framesToRead = min(inputFrameCapacity, remaining)
                if framesToRead == 0 {
                    endFlag.value = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                try audioFile.read(into: buffer, frameCount: framesToRead)
                if buffer.frameLength == 0 {
                    endFlag.value = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return buffer
            } catch {
                outStatus.pointee = .noDataNow
                return nil
            }
        }
        
        while true {
            let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity)!
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
            if status == .error {
                throw error ?? InferenceError.processingFailed
            }
            if outputBuffer.frameLength > 0 {
                try outputFile.write(from: outputBuffer)
            }
            if status == .endOfStream {
                break
            }
        }
        
        return outputUrl
    }
    
    private func validateAudioFile(_ audioFile: AVAudioFile) throws {
        guard audioFile.length > 0 else {
            throw InferenceError.processingFailed // Empty file
        }
        // Additional checks...
    }
    
    private func runParallelInference(audioPath: String, taskId: String, modelManager: WhisperModelManager, debugExport: Bool, enableRoleSplit: Bool) async throws -> FusedResult {
        try await withThrowingTaskGroup(of: InferenceResult.self) { group in
            // Task A: ASR
            group.addTask {
                guard let pipe = modelManager.pipe else {
                    throw InferenceError.modelNotLoaded
                }
                
                var partialSegments: [TranscriptSegment] = []
                let previousCallback = pipe.segmentDiscoveryCallback
                pipe.segmentDiscoveryCallback = { segments in
                    let mapped = segments.map { TranscriptSegment(start: Double($0.start), end: Double($0.end), text: $0.text) }
                    partialSegments.append(contentsOf: mapped)
                    let fused = partialSegments.map { FusedSegment(start: $0.start, end: $0.end, text: $0.text, speaker: enableRoleSplit ? "Unknown" : "") }
                    let text = fused.map { $0.text }.joined(separator: " ")
                    let partial = FusedResult(text: text, segments: fused)
                    let payload = self.formatOutput(partial, isPartial: true)
                    Task { await LocalTaskManager.shared.updatePartial(taskId, result: payload) }
                }
                defer { pipe.segmentDiscoveryCallback = previousCallback }
                
                let results = try await pipe.transcribe(audioPath: audioPath)
                let wSegments = results.flatMap { $0.segments }
                
                let transcriptSegments = wSegments.map { s in
                    TranscriptSegment(start: Double(s.start), end: Double(s.end), text: s.text)
                }
                
                let fullText = transcriptSegments.map { $0.text }.joined(separator: " ")
                
                return .asr(ASRResult(text: fullText, segments: transcriptSegments))
            }
            
            // Task B: Diarization
            if enableRoleSplit {
                group.addTask {
                    let result = try await FluidAudio.shared.diarize(audioPath: audioPath)
                    return .diarization(result)
                }
            }
            
            var asrResult: ASRResult?
            var diarizationResult: DiarizationResult?
            
            for try await result in group {
                switch result {
                case .asr(let r): asrResult = r
                case .diarization(let r): diarizationResult = r
                }
            }
            
            guard let asr = asrResult else {
                throw InferenceError.partialFailure
            }
            
            if !enableRoleSplit {
                let fusedSegments = asr.segments.map { segment in
                    FusedSegment(start: segment.start, end: segment.end, text: segment.text, speaker: "")
                }
                return FusedResult(text: asr.text, segments: fusedSegments)
            }
            
            guard let diar = diarizationResult else {
                throw InferenceError.partialFailure
            }
            
            if debugExport {
                exportRawResults(asr: asr, diarization: diar)
            }
            
            return performFusion(asr: asr, diarization: diar)
        }
    }
    
    private func exportRawResults(asr: ASRResult, diarization: DiarizationResult) {
        let tempDir = FileManager.default.temporaryDirectory
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        do {
            let asrData = try encoder.encode(asr.segments)
            let asrPath = tempDir.appendingPathComponent("debug_raw_asr.json")
            try asrData.write(to: asrPath)
            
            let diarData = try encoder.encode(diarization.segments)
            let diarPath = tempDir.appendingPathComponent("debug_raw_diarization.json")
            try diarData.write(to: diarPath)
            
            print("[Debug] Exported raw results to \(tempDir.path)")
        } catch {
            print("[Debug] Failed to export raw results: \(error)")
        }
    }
    
    private func performFusion(asr: ASRResult, diarization: DiarizationResult) -> FusedResult {
        let speakers = diarization.segments
        
        let fusedSegments = asr.segments.map { segment -> FusedSegment in
            let speakerId = assignSpeakerToTranscript(transcript: segment, speakers: speakers) ?? "Unknown"
            return FusedSegment(start: segment.start, end: segment.end, text: segment.text, speaker: speakerId)
        }
        
        return FusedResult(text: asr.text, segments: fusedSegments)
    }
    
    private func assignSpeakerToTranscript(transcript: TranscriptSegment, speakers: [SpeakerSegment]) -> String? {
        let windowStart = transcript.start
        let windowEnd = transcript.end
        
        let overlappingSpeakers = speakers.filter { speaker in
            speaker.start < windowEnd && speaker.end > windowStart
        }
        
        return overlappingSpeakers
            .map { ($0, min($0.end, windowEnd) - max($0.start, windowStart)) }
            .max(by: { $0.1 < $1.1 })?
            .0.speakerId
    }
    
    nonisolated private func formatOutput(_ result: FusedResult, isPartial: Bool = false) -> [String: Any] {
        let segments = result.segments.map { segment in
            var payload: [String: Any] = [
                "start": segment.start,
                "end": segment.end,
                "text": segment.text
            ]
            if !segment.speaker.isEmpty {
                payload["speaker"] = segment.speaker
            }
            return payload
        }
        
        var payload: [String: Any] = [
            "text": result.text,
            "segments": segments,
            "provider": "localWhisper"
        ]
        if isPartial {
            payload["partial"] = true
        }
        return payload
    }
}
