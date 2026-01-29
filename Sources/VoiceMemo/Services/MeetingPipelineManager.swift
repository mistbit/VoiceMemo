import Foundation
import Combine

class MeetingPipelineManager: ObservableObject {
    @Published var task: MeetingTask
    @Published var isProcessing: Bool = false
    @Published var errorMessage: String?
    
    private let ossService: OSSService
    private let tingwuService: TingwuService
    private let settings: SettingsStore
    
    private struct PipelineConstants {
        static let maxPollingRetries = 60
        static let pollingInterval: UInt64 = 2 * 1_000_000_000
    }
    
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

    func prepareForRerun(step: MeetingTaskStatus, speaker: Int? = nil) async {
        let (mixedRawPath, mixedTranscodedPath, speaker1RawPath, speaker1TranscodedPath, speaker2RawPath, speaker2TranscodedPath) = await MainActor.run {
            let mixedRaw = preferredRawPath(for: task.localFilePath)
            let mixedTranscoded = inferredTranscodedPath(for: mixedRaw, channelId: 0)
            let s1Raw = task.speaker1AudioPath.map { preferredRawPath(for: $0) }
            let s1Transcoded = s1Raw.map { inferredTranscodedPath(for: $0, channelId: 1) }
            let s2Raw = task.speaker2AudioPath.map { preferredRawPath(for: $0) }
            let s2Transcoded = s2Raw.map { inferredTranscodedPath(for: $0, channelId: 2) }
            return (mixedRaw, mixedTranscoded, s1Raw, s1Transcoded, s2Raw, s2Transcoded)
        }
        
        let shouldClearMixed = (task.mode == .mixed) && (speaker == nil || speaker == 0)
        let shouldClearSpk1 = (task.mode == .separated) && (speaker == nil || speaker == 1)
        let shouldClearSpk2 = (task.mode == .separated) && (speaker == nil || speaker == 2)

        if step == .transcoding {
            if shouldClearMixed && FileManager.default.fileExists(atPath: mixedTranscodedPath) {
                try? FileManager.default.removeItem(atPath: mixedTranscodedPath)
            }
            if shouldClearSpk1, let path = speaker1TranscodedPath, FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
            if shouldClearSpk2, let path = speaker2TranscodedPath, FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }

        await MainActor.run {
            var t = self.task

            if step == .uploadingRaw || step == .transcoding {
                if shouldClearMixed { t.localFilePath = mixedRawPath }
                if shouldClearSpk1 { t.speaker1AudioPath = speaker1RawPath }
                if shouldClearSpk2 { t.speaker2AudioPath = speaker2RawPath }
            }

            switch step {
            case .uploadingRaw:
                if shouldClearMixed {
                    t.originalOssUrl = nil; t.ossUrl = nil; t.tingwuTaskId = nil
                    t.transcript = nil; t.summary = nil
                    t.status = .recorded
                }
                if shouldClearSpk1 {
                    t.originalOssUrl = nil; t.ossUrl = nil; t.tingwuTaskId = nil
                    t.speaker1Transcript = nil
                    // Note: In separated mode, we might want to track status per speaker,
                    // but we also reset global status to reflect "work in progress" if we want the main UI to update.
                    // However, let's stick to updating speaker status.
                    t.speaker1Status = nil 
                }
                if shouldClearSpk2 {
                    t.speaker2OriginalOssUrl = nil; t.speaker2OssUrl = nil; t.speaker2TingwuTaskId = nil
                    t.speaker2Transcript = nil
                    t.speaker2Status = nil
                }
            case .transcoding:
                if shouldClearMixed {
                    t.ossUrl = nil; t.tingwuTaskId = nil
                    t.transcript = nil; t.summary = nil
                    t.status = .uploadedRaw
                }
                if shouldClearSpk1 {
                    t.ossUrl = nil; t.tingwuTaskId = nil
                    t.speaker1Transcript = nil
                    t.speaker1Status = nil
                }
                if shouldClearSpk2 {
                    t.speaker2OssUrl = nil; t.speaker2TingwuTaskId = nil
                    t.speaker2Transcript = nil
                    t.speaker2Status = nil
                }
            case .uploading:
                if shouldClearMixed {
                    t.ossUrl = nil; t.tingwuTaskId = nil
                    t.transcript = nil; t.summary = nil
                    t.status = .transcoded
                }
                if shouldClearSpk1 {
                    t.ossUrl = nil; t.tingwuTaskId = nil
                    t.speaker1Transcript = nil
                    t.speaker1Status = nil
                }
                if shouldClearSpk2 {
                    t.speaker2OssUrl = nil; t.speaker2TingwuTaskId = nil
                    t.speaker2Transcript = nil
                    t.speaker2Status = nil
                }
            case .created:
                if shouldClearMixed {
                    t.tingwuTaskId = nil
                    t.transcript = nil; t.summary = nil
                    t.status = .uploaded
                }
                if shouldClearSpk1 {
                    t.tingwuTaskId = nil
                    t.speaker1Transcript = nil
                    t.speaker1Status = nil
                }
                if shouldClearSpk2 {
                    t.speaker2TingwuTaskId = nil
                    t.speaker2Transcript = nil
                    t.speaker2Status = nil
                }
            case .polling:
                if shouldClearMixed {
                    t.transcript = nil; t.summary = nil
                    t.status = .created
                }
                if shouldClearSpk1 {
                    t.speaker1Transcript = nil
                    t.speaker1Status = nil
                }
                if shouldClearSpk2 {
                    t.speaker2Transcript = nil
                    t.speaker2Status = nil
                }
            default:
                break
            }

            if shouldClearMixed { t.lastError = nil; t.failedStep = nil }
            if shouldClearSpk1 { t.speaker1FailedStep = nil }
            if shouldClearSpk2 { t.speaker2FailedStep = nil }

            self.task = t
            self.errorMessage = nil
            self.isProcessing = false
        }

        self.save()
    }
    
    // MARK: - Retry Logic
    
    func retry() async {
        await retry(speaker: nil)
    }
    
    func retry(speaker: Int?) async {
        settings.log("Retry requested for speaker: \(speaker ?? 0)")
        
        if task.mode == .mixed {
            let startStep = task.failedStep ?? .recorded
            await prepareForRerun(step: startStep, speaker: nil)
            await runPipeline(from: startStep, targetSpeaker: nil)
        } else {
            // Separated Mode
            if let spk = speaker {
                let startStep: MeetingTaskStatus
                if spk == 1 {
                    startStep = task.speaker1FailedStep ?? .recorded
                } else {
                    startStep = task.speaker2FailedStep ?? .recorded
                }
                await prepareForRerun(step: startStep, speaker: spk)
                await runSingleTrack(from: startStep, speaker: spk)
                await tryAlign()
            } else {
                // Global rerun for separated mode: clear everything and start from beginning
                await prepareForRerun(step: .recorded, speaker: nil)
                await runSeparatedPipeline()
            }
        }
    }
    
    func restartFromBeginning() async {
        settings.log("Restart from beginning")
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
    
    // MARK: - Pipeline Orchestration
    
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
        if (speaker == 1 && task.speaker1Status == .completed && startStep != .polling) ||
           (speaker == 2 && task.speaker2Status == .completed && startStep != .polling) {
            return
        }
        
        let nodes = buildChain(from: startStep, channelId: speaker)
        await executeChain(nodes: nodes, speaker: speaker)
    }
    
    private func runPipeline(from startStep: MeetingTaskStatus, targetSpeaker: Int?) async {
        let nodes = buildChain(from: startStep, channelId: targetSpeaker ?? 0)
        await executeChain(nodes: nodes, speaker: targetSpeaker)
    }
    
    private func buildChain(from startStep: MeetingTaskStatus, channelId: Int) -> [PipelineNode] {
        var nodes: [PipelineNode] = []
        
        if startStep == .recorded || startStep == .failed {
            nodes.append(UploadOriginalNode(channelId: channelId))
        } else if startStep == .uploadingRaw {
            nodes.append(UploadOriginalNode(channelId: channelId))
        } else if startStep == .uploadedRaw || startStep == .transcoding {
            nodes.append(TranscodeNode(channelId: channelId))
        } else if startStep == .transcoded || startStep == .uploading {
            nodes.append(UploadNode(channelId: channelId))
        } else if startStep == .uploaded || startStep == .created {
            nodes.append(CreateTaskNode(channelId: channelId))
        } else if startStep == .polling {
            nodes.append(PollingNode(channelId: channelId))
        }
        
        return nodes
    }
    
    // MARK: - Board & Execution Logic
    
    private func executeChain(nodes: [PipelineNode], speaker: Int?) async {
        // 1. Hydrate Board from Task
        let taskSnapshot = await MainActor.run { self.task }
        var board = createBoard(from: taskSnapshot)
        let services = ServiceProvider(ossService: ossService, tingwuService: tingwuService)
        let channelId = speaker ?? 0
        
        await MainActor.run { self.isProcessing = true }
        
        for node in nodes {
            // Update UI status to "Running"
            await updateStatus(node.step, speaker: speaker, isFailed: false)
            
            var success = false
            var retryCount = 0
            
            while !success {
                do {
                    // 2. Run Node (Pure execution on Board)
                    try await node.run(board: &board, services: services)
                    
                    // 3. Persist State (Sync Board back to Task)
                    await persistState(from: board, channelId: channelId, completedStep: node.step)
                    success = true
                    
                } catch {
                    // Handle PipelineError with type safety
                    if let pipelineError = error as? PipelineError {
                        switch pipelineError {
                        case .taskRunning:
                            retryCount += 1
                            if retryCount > PipelineConstants.maxPollingRetries {
                                await updateStatus(.failed, speaker: speaker, step: node.step, error: "Polling timeout", isFailed: true)
                                return
                            }
                            try? await Task.sleep(nanoseconds: PipelineConstants.pollingInterval)
                            continue
                        case .channelNotFound(let id):
                            await updateStatus(.failed, speaker: speaker, step: node.step, error: "Channel \(id) not found", isFailed: true)
                            return
                        case .inputMissing(let msg):
                            await updateStatus(.failed, speaker: speaker, step: node.step, error: "Input missing: \(msg)", isFailed: true)
                            return
                        case .transcodeFailed:
                            await updateStatus(.failed, speaker: speaker, step: node.step, error: "Transcoding failed", isFailed: true)
                            return
                        case .cloudError(let msg):
                            await updateStatus(.failed, speaker: speaker, step: node.step, error: "Cloud service error: \(msg)", isFailed: true)
                            return
                        case .taskFailed(let msg):
                            await updateStatus(.failed, speaker: speaker, step: node.step, error: "Task failed: \(msg)", isFailed: true)
                            return
                        }
                    }
                    
                    // Backward compatibility: handle non-PipelineError NSError
                    let nsError = error as NSError
                    if nsError.code == 202 {
                        retryCount += 1
                        if retryCount > PipelineConstants.maxPollingRetries {
                            await updateStatus(.failed, speaker: speaker, step: node.step, error: "Polling timeout", isFailed: true)
                            return
                        }
                        try? await Task.sleep(nanoseconds: PipelineConstants.pollingInterval)
                        continue
                    }
                    
                    // Unknown error
                    await updateStatus(.failed, speaker: speaker, step: node.step, error: error.localizedDescription, isFailed: true)
                    return
                }
            }
        }
        
        await MainActor.run { self.isProcessing = false }
    }
    
    // MARK: - Hydration & Persistence
    
    private func createBoard(from task: MeetingTask) -> PipelineBoard {
        let config = PipelineBoard.Config(
            ossPrefix: settings.ossPrefix,
            tingwuAppKey: settings.tingwuAppKey,
            enableSummarization: settings.enableSummary,
            enableMeetingAssistance: settings.enableKeyPoints || settings.enableActionItems,
            enableSpeakerDiarization: settings.enableRoleSplit,
            speakerCount: settings.speakerCount
        )
        
        var board = PipelineBoard(
            recordingId: task.recordingId,
            creationDate: task.createdAt,
            mode: task.mode,
            config: config
        )
        
        // Hydrate Mixed Channel (0)
        var mixed = ChannelData()
        mixed.rawAudioPath = preferredRawPath(for: task.localFilePath)
        let mixedTranscoded = inferredTranscodedPath(for: mixed.rawAudioPath!, channelId: 0)
        if FileManager.default.fileExists(atPath: mixedTranscoded) {
            mixed.processedAudioPath = mixedTranscoded
        } else {
            // Fallback: if localFilePath points to the processed file (legacy/reused field)
            // But we should be careful. Let's trust inferred path first.
            // If inferred file doesn't exist, maybe the task is not transcoded yet.
            // Keeping processedAudioPath nil is safer than assigning raw path.
            // However, to be compatible with existing logic where localFilePath might BE the processed path:
            if task.localFilePath.hasSuffix("_48k.m4a") {
                mixed.processedAudioPath = task.localFilePath
            }
        }
        mixed.rawAudioOssURL = task.originalOssUrl
        mixed.processedAudioOssURL = task.ossUrl
        mixed.tingwuTaskId = task.tingwuTaskId
        board.channels[0] = mixed
        
        // Hydrate Speaker Channels (Separated Mode)
        if task.mode == .separated {
            // Speaker 1 (Channel 1)
            var spk1 = ChannelData()
            if let p = task.speaker1AudioPath {
                spk1.rawAudioPath = preferredRawPath(for: p)
                let t = inferredTranscodedPath(for: spk1.rawAudioPath!, channelId: 1)
                if FileManager.default.fileExists(atPath: t) {
                    spk1.processedAudioPath = t
                } else if p.hasSuffix("_48k.m4a") {
                    spk1.processedAudioPath = p
                }
            }
            spk1.rawAudioOssURL = task.originalOssUrl
            spk1.processedAudioOssURL = task.ossUrl
            spk1.tingwuTaskId = task.tingwuTaskId
            spk1.failedStep = task.speaker1FailedStep
            if let transcriptText = task.speaker1Transcript {
                spk1.transcript = TingwuResult(text: transcriptText)
            }
            if task.speaker1Status == .failed {
                spk1.lastError = task.lastError
            }
            board.channels[1] = spk1
            
            // Speaker 2 (Channel 2)
            var spk2 = ChannelData()
            if let p = task.speaker2AudioPath {
                spk2.rawAudioPath = preferredRawPath(for: p)
                let t = inferredTranscodedPath(for: spk2.rawAudioPath!, channelId: 2)
                if FileManager.default.fileExists(atPath: t) {
                    spk2.processedAudioPath = t
                } else if p.hasSuffix("_48k.m4a") {
                    spk2.processedAudioPath = p
                }
            }
            spk2.rawAudioOssURL = task.speaker2OriginalOssUrl
            spk2.processedAudioOssURL = task.speaker2OssUrl
            spk2.tingwuTaskId = task.speaker2TingwuTaskId
            spk2.failedStep = task.speaker2FailedStep
            if let transcriptText = task.speaker2Transcript {
                spk2.transcript = TingwuResult(text: transcriptText)
            }
            if task.speaker2Status == .failed {
                spk2.lastError = task.lastError
            }
            board.channels[2] = spk2
        }
        
        return board
    }

    private func preferredRawPath(for path: String) -> String {
        let candidate = inferredRawPath(from: path)
        if FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return path
    }

    private func inferredRawPath(from path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let dir = url.deletingLastPathComponent()
        if name == "mixed_48k.m4a" {
            return dir.appendingPathComponent("mixed.m4a").path
        }
        if name.hasSuffix("_48k.m4a") {
            let rawName = name.replacingOccurrences(of: "_48k.m4a", with: ".m4a")
            return dir.appendingPathComponent(rawName).path
        }
        return path
    }

    private func inferredTranscodedPath(for rawPath: String, channelId: Int) -> String {
        let url = URL(fileURLWithPath: rawPath)
        let dir = url.deletingLastPathComponent()
        let name = channelId == 0 ? "mixed_48k.m4a" : "speaker\(channelId)_48k.m4a"
        return dir.appendingPathComponent(name).path
    }
    
    private func persistState(from board: PipelineBoard, channelId: Int, completedStep: MeetingTaskStatus) async {
        guard let channel = board.channels[channelId] else { return }
        
        await MainActor.run {
            updateChannelFields(channelId: channelId, channel: channel)
            updateChannelStatus(channelId: channelId, completedStep: completedStep)
            self.errorMessage = nil
            self.save()
        }
    }
    
    private func updateChannelFields(channelId: Int, channel: ChannelData) {
        switch channelId {
        case 0:
            if let url = channel.rawAudioOssURL { self.task.originalOssUrl = url }
            if let path = channel.processedAudioPath { self.task.localFilePath = path }
            if let url = channel.processedAudioOssURL { self.task.ossUrl = url }
            if let tid = channel.tingwuTaskId { self.task.tingwuTaskId = tid }
            if let res = channel.transcript {
                self.task.transcript = res.text
                if let sum = res.summary { self.task.summary = sum }
            }
        case 1:
            if let url = channel.rawAudioOssURL { self.task.originalOssUrl = url }
            if let path = channel.processedAudioPath { self.task.speaker1AudioPath = path }
            if let url = channel.processedAudioOssURL { self.task.ossUrl = url }
            if let tid = channel.tingwuTaskId { self.task.tingwuTaskId = tid }
            if let res = channel.transcript { self.task.speaker1Transcript = res.text }
        case 2:
            if let url = channel.rawAudioOssURL { self.task.speaker2OriginalOssUrl = url }
            if let path = channel.processedAudioPath { self.task.speaker2AudioPath = path }
            if let url = channel.processedAudioOssURL { self.task.speaker2OssUrl = url }
            if let tid = channel.tingwuTaskId { self.task.speaker2TingwuTaskId = tid }
            if let res = channel.transcript { self.task.speaker2Transcript = res.text }
        default:
            break
        }
    }
    
    private func updateChannelStatus(channelId: Int, completedStep: MeetingTaskStatus) {
        let postStatus: MeetingTaskStatus? = {
            switch completedStep {
            case .uploadingRaw: return .uploadedRaw
            case .transcoding: return .transcoded
            case .uploading: return .uploaded
            case .created: return .created
            case .polling: return .completed
            default: return nil
            }
        }()
        
        guard let status = postStatus else { return }
        
        switch channelId {
        case 0:
            self.task.status = status
        case 1:
            self.task.speaker1Status = status
        case 2:
            self.task.speaker2Status = status
        default:
            break
        }
    }
    
    // MARK: - Helpers
    
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
                    self.task.status = .failed
                } else {
                    self.task.status = .failed
                    self.task.failedStep = step
                }
                self.task.lastError = error
                self.errorMessage = error
                self.isProcessing = false
            } else {
                if let spk = speaker {
                    if spk == 1 { self.task.speaker1Status = status }
                    else { self.task.speaker2Status = status }
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
    
    // MARK: - Legacy Support for Tests
    
    func buildTranscriptText(from transcriptionData: [String: Any]) -> String {
        return TranscriptParser.buildTranscriptText(from: transcriptionData) ?? ""
    }
    
    private func save() {
        Task { @MainActor in
            let snapshot = self.task
            try? await StorageManager.shared.currentProvider.saveTask(snapshot)
        }
    }
}
