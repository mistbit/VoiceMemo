import Foundation
import Combine

class MeetingPipelineManager: ObservableObject {
    @Published var task: MeetingTask
    @Published var isProcessing: Bool = false
    @Published var errorMessage: String?
    
    private let ossService: OSSService
    private let tingwuService: TingwuService
    private let settings: SettingsStore
    
    init(task: MeetingTask, settings: SettingsStore) {
        self.task = task
        self.settings = settings
        self.ossService = OSSService(settings: settings)
        self.tingwuService = TingwuService(settings: settings)
    }
    
    // MARK: - Public Actions
    
    func start() async {
        await uploadOriginal()
    }
    
    func transcode(force: Bool = false) async {
        if !force && task.status != .uploadedRaw && task.status != .failed { return }
        
        if task.mode == .mixed {
            await runPipeline(from: .transcoding, targetSpeaker: nil)
        } else {
            await runSeparatedPipeline(from: .transcoding)
        }
    }
    
    // Legacy support for View buttons calling specific steps
    // We map them to running the pipeline from that step
    func upload() async {
        if task.mode == .mixed {
            await runPipeline(from: .uploading, targetSpeaker: nil)
        } else {
            await runSeparatedPipeline(from: .uploading)
        }
    }
    
    func uploadOriginal() async {
        if task.mode == .mixed {
            await runPipeline(from: .uploadingRaw, targetSpeaker: nil)
        } else {
            await runSeparatedPipeline(from: .uploadingRaw)
        }
    }
    
    func createTask() async {
        if task.mode == .mixed {
            await runPipeline(from: .created, targetSpeaker: nil)
        } else {
            await runSeparatedPipeline(from: .created)
        }
    }
    
    func pollStatus() async {
        if task.mode == .mixed {
            await runPipeline(from: .polling, targetSpeaker: nil)
        } else {
            await runSeparatedPipeline(from: .polling)
        }
    }
    
    // MARK: - Retry Logic
    
    func retry() async {
        await retry(speaker: nil)
    }
    
    func retry(speaker: Int?) async {
        settings.log("Retry requested for speaker: \(speaker ?? 0)")
        
        if task.mode == .mixed {
            let startStep = task.failedStep ?? .recorded
            await runPipeline(from: startStep, targetSpeaker: nil)
        } else {
            // Separated Mode
            if let spk = speaker {
                // Retry specific speaker
                let startStep: MeetingTaskStatus
                if spk == 1 {
                    startStep = task.speaker1FailedStep ?? .recorded
                } else {
                    startStep = task.speaker2FailedStep ?? .recorded
                }
                await runSingleTrack(from: startStep, speaker: spk)
                
                // After single track finishes, try alignment if both ready
                await tryAlign()
            } else {
                // Retry both (legacy behavior or generic retry button)
                await runSeparatedPipeline()
            }
        }
    }
    
    func restartFromBeginning() async {
        settings.log("Restart from beginning")
        // Reset Task
        var resetTask = task
        resetTask.status = .recorded
        resetTask.originalOssUrl = nil
        resetTask.speaker2OriginalOssUrl = nil
        resetTask.ossUrl = nil
        resetTask.speaker2OssUrl = nil
        resetTask.tingwuTaskId = nil
        resetTask.speaker2TingwuTaskId = nil
        resetTask.transcript = nil
        resetTask.speaker1Transcript = nil
        resetTask.speaker2Transcript = nil
        resetTask.summary = nil
        resetTask.failedStep = nil
        resetTask.speaker1FailedStep = nil
        resetTask.speaker2FailedStep = nil
        resetTask.speaker1Status = nil
        resetTask.speaker2Status = nil
        
        self.task = resetTask
        self.save()
        
        await start()
    }
    
    // MARK: - Pipeline Execution
    
    private func runMixedPipeline() async {
        await runPipeline(from: .recorded, targetSpeaker: nil)
    }
    
    private func runSeparatedPipeline(from step: MeetingTaskStatus = .recorded) async {
        async let t1: Void = runSingleTrack(from: step == .transcoding ? (task.speaker1Status == .completed ? .completed : step) : step, speaker: 1)
        async let t2: Void = runSingleTrack(from: step == .transcoding ? (task.speaker2Status == .completed ? .completed : step) : step, speaker: 2)
        
        _ = await (t1, t2)
        await tryAlign()
    }
    
    private func runSingleTrack(from startStep: MeetingTaskStatus, speaker: Int) async {
        // If already completed, skip unless forced (not handled here for simplicity)
        if (speaker == 1 && task.speaker1Status == .completed && startStep != .polling) ||
           (speaker == 2 && task.speaker2Status == .completed && startStep != .polling) {
            return
        }
        
        var nodes: [PipelineNode] = []
        
        // Build chain based on startStep
        if startStep == .recorded || startStep == .failed {
            nodes.append(UploadOriginalNode(targetSpeaker: speaker))
        } else if startStep == .uploadingRaw {
            nodes.append(UploadOriginalNode(targetSpeaker: speaker))
        } else if startStep == .uploadedRaw || startStep == .transcoding {
            nodes.append(TranscodeNode(targetSpeaker: speaker))
        } else if startStep == .transcoded || startStep == .uploading {
            nodes.append(UploadNode(targetSpeaker: speaker))
        } else if startStep == .uploaded || startStep == .created {
            nodes.append(CreateTaskNode(targetSpeaker: speaker))
        } else if startStep == .polling {
            nodes.append(PollingNode(targetSpeaker: speaker))
        }
        
        await executeChain(nodes: nodes, speaker: speaker)
    }
    
    private func runPipeline(from startStep: MeetingTaskStatus, targetSpeaker: Int?) async {
        var nodes: [PipelineNode] = []
        
        // Logic for mixed mode mainly
        if startStep == .recorded || startStep == .failed {
            nodes.append(UploadOriginalNode(targetSpeaker: targetSpeaker))
        } else if startStep == .uploadingRaw {
            nodes.append(UploadOriginalNode(targetSpeaker: targetSpeaker))
        } else if startStep == .uploadedRaw || startStep == .transcoding {
            nodes.append(TranscodeNode(targetSpeaker: targetSpeaker))
        } else if startStep == .transcoded || startStep == .uploading {
            nodes.append(UploadNode(targetSpeaker: targetSpeaker))
        } else if startStep == .uploaded || startStep == .created {
            nodes.append(CreateTaskNode(targetSpeaker: targetSpeaker))
        } else if startStep == .polling {
            nodes.append(PollingNode(targetSpeaker: targetSpeaker))
        }
        
        await executeChain(nodes: nodes, speaker: targetSpeaker)
    }
    
    private func executeChain(nodes: [PipelineNode], speaker: Int?) async {
        await MainActor.run { self.isProcessing = true }
        
        for node in nodes {
            // 1. Update Status to Running
            await updateStatus(node.step, speaker: speaker, isFailed: false)
            
            // 2. Run Node
            var success = false
            var retryCount = 0
            let maxRetries = 60 // For polling
            
            while !success {
                do {
                    let context = PipelineContext(task: self.task, settings: self.settings, ossService: self.ossService, tingwuService: self.tingwuService)
                    let updatedTask = try await node.run(context: context)
                    
                    await MainActor.run {
                        self.task = updatedTask
                        // Specific status updates for separated mode
                        if let spk = speaker {
                            if spk == 1 { self.task.speaker1Status = node.step == .polling ? .completed : node.step }
                            else { self.task.speaker2Status = node.step == .polling ? .completed : node.step }
                        }
                    }
                    
                    let postStatus: MeetingTaskStatus? = {
                        switch node.step {
                        case .uploadingRaw: return .uploadedRaw
                        case .transcoding: return .transcoded
                        case .uploading: return .uploaded
                        case .created: return .created
                        case .polling, .recorded, .failed, .completed, .uploadedRaw, .transcoded, .uploaded: return nil
                        }
                    }()
                    if let postStatus {
                        await updateStatus(postStatus, speaker: speaker, isFailed: false)
                    }
                    
                    self.save()
                    success = true
                    
                } catch {
                    let nsError = error as NSError
                    if nsError.code == 202 && node is PollingNode {
                        // Polling: wait and retry
                        retryCount += 1
                        if retryCount > maxRetries {
                            await updateStatus(.failed, speaker: speaker, step: node.step, error: "Polling timeout", isFailed: true)
                            return
                        }
                        try? await Task.sleep(nanoseconds: 2 * 1_000_000_000) // 2s
                        continue
                    } else {
                        // Real failure
                        await updateStatus(.failed, speaker: speaker, step: node.step, error: error.localizedDescription, isFailed: true)
                        return
                    }
                }
            }
        }
        
        // Chain completed
        await MainActor.run { self.isProcessing = false }
    }
    
    private func updateStatus(_ status: MeetingTaskStatus, speaker: Int?, step: MeetingTaskStatus? = nil, error: String? = nil, isFailed: Bool = false) async {
        await MainActor.run {
            if isFailed {
                if let spk = speaker {
                    if spk == 1 {
                        self.task.speaker1Status = .failed
                        self.task.speaker1FailedStep = step
                    } else {
                        self.task.speaker2Status = .failed
                        self.task.speaker2FailedStep = step
                    }
                    // Global status update?
                    self.task.status = .failed
                } else {
                    self.task.status = .failed
                    self.task.failedStep = step
                }
                self.task.lastError = error
                self.errorMessage = error
                self.isProcessing = false
            } else {
                // Running status
                if let spk = speaker {
                    if spk == 1 { self.task.speaker1Status = status }
                    else { self.task.speaker2Status = status }
                    // Update global status to something meaningful?
                    if self.task.status != .polling { self.task.status = status }
                } else {
                    self.task.status = status
                }
                self.errorMessage = nil
            }
        }
        self.save()
    }
    
    private func tryAlign() async {
        // Only if both are done (or one done one failed?)
        // For now, simple merge if both have content
        await MainActor.run {
            let t1 = self.task.speaker1Transcript ?? ""
            let t2 = self.task.speaker2Transcript ?? ""
            
            if !t1.isEmpty || !t2.isEmpty {
                var merged = ""
                if !t1.isEmpty { merged += "### Speaker 1 (Local)\n\(t1)\n\n" }
                if !t2.isEmpty { merged += "### Speaker 2 (Remote)\n\(t2)\n" }
                self.task.transcript = merged
                self.task.status = .completed
                self.save()
            }
        }
    }
    
    func buildTranscriptText(from transcriptionData: [String: Any]) -> String {
        func build(from data: [String: Any]) -> String? {
            if let result = data["Result"] as? [String: Any],
               let transcription = result["Transcription"] as? [String: Any] {
                return build(from: transcription)
            }
            if let transcription = data["Transcription"] as? [String: Any] {
                return build(from: transcription)
            }
            if let paragraphs = data["Paragraphs"] as? [[String: Any]] {
                return paragraphs.compactMap { extractLine(from: $0) }.joined(separator: "\n")
            }
            if let sentences = data["Sentences"] as? [[String: Any]] {
                return sentences.compactMap { extractLine(from: $0) }.joined(separator: "\n")
            }
            if let transcript = data["Transcript"] as? String {
                return transcript
            }
            return nil
        }
        
        func extractLine(from item: [String: Any]) -> String? {
            let speaker = extractSpeaker(from: item)
            let text = extractText(from: item)
            guard !text.isEmpty else { return nil }
            if let speaker {
                return "\(speaker): \(text)"
            }
            return text
        }
        
        func extractText(from item: [String: Any]) -> String {
            if let text = item["Text"] as? String, !text.isEmpty { return text }
            if let text = item["text"] as? String, !text.isEmpty { return text }
            if let words = item["Words"] as? [[String: Any]] {
                return words.compactMap { $0["Text"] as? String ?? $0["text"] as? String }.joined()
            }
            return ""
        }
        
        func extractSpeaker(from item: [String: Any]) -> String? {
            if let name = item["SpeakerName"] as? String, !name.isEmpty { return name }
            if let name = item["Speaker"] as? String, !name.isEmpty { return name }
            if let id = item["SpeakerId"] ?? item["SpeakerID"] { return "Speaker \(id)" }
            return nil
        }
        
        return build(from: transcriptionData) ?? ""
    }

    private func save() {
        Task { try? await StorageManager.shared.currentProvider.saveTask(self.task) }
    }
}
