import Foundation
import Combine

class MeetingPipelineManager: ObservableObject {
    @Published var task: MeetingTask
    @Published var isProcessing: Bool = false
    @Published var errorMessage: String?
    
    private let ossService: OSSService
    private let transcriptionService: TranscriptionService
    // private let tingwuService: TingwuService // Removed in favor of protocol
    private let settings: SettingsStore
    
    private struct PipelineConstants {
        static let maxPollingRetries = 60
        static let pollingInterval: UInt64 = 2 * 1_000_000_000
    }
    
    init(task: MeetingTask, settings: SettingsStore) {
        self.task = task
        self.settings = settings
        self.ossService = OSSService(settings: settings)
        
        // Factory logic for TranscriptionService
        switch settings.asrProvider {
        case .tingwu:
            self.transcriptionService = TingwuService(settings: settings)
        case .volcengine:
            self.transcriptionService = VolcengineService(settings: settings)
        }
    }

    var activeTranscriptionService: TranscriptionService {
        transcriptionService
    }
    
    // MARK: - Public Actions
    
    func start() async {
        await uploadOriginal()
    }
    
    func transcode(force: Bool = false) async {
        if !force && task.status != .uploadedRaw && task.status != .failed { return }
        await runPipeline(from: .transcoding)
    }
    
    func upload() async {
        await runPipeline(from: .uploading)
    }
    
    func uploadOriginal() async {
        await runPipeline(from: .uploadingRaw)
    }
    
    func createTask() async {
        await runPipeline(from: .created)
    }
    
    func pollStatus() async {
        await runPipeline(from: .polling)
    }
    
    // MARK: - Retry Logic
    
    func retry() async {
        settings.log("Retry requested")
        let startStep = task.failedStep ?? .recorded
        await runPipeline(from: startStep)
    }
    
    func restartFromBeginning() async {
        settings.log("Restart from beginning")
        let resetTask = task
        resetTask.status = .recorded
        resetTask.originalOssUrl = nil
        resetTask.ossUrl = nil
        resetTask.transcriptionTaskId = nil
        resetTask.transcript = nil
        resetTask.summary = nil
        resetTask.failedStep = nil
        
        self.task = resetTask
        await self.save()
        
        await start()
    }
    
    // MARK: - Pipeline Orchestration
    
    private func runPipeline(from startStep: MeetingTaskStatus) async {
        let nodes = buildChain(from: startStep, channelId: 0)
        await executeChain(nodes: nodes)
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
    
    private func executeChain(nodes: [PipelineNode]) async {
        let taskSnapshot = await MainActor.run { self.task }
        var board = createBoard(from: taskSnapshot)
        let services = ServiceProvider(ossService: ossService, transcriptionService: transcriptionService)
        
        await MainActor.run { self.isProcessing = true }
        
        var isChainCompleted = true
        
        for node in nodes {
            await updateStatus(node.step, isFailed: false)
            
            var success = false
            var retryCount = 0
            
            while !success {
                do {
                    try await node.run(board: &board, services: services)
                    
                    await persistState(from: board, channelId: 0, completedStep: node.step)
                    success = true
                    
                } catch {
                    if let pipelineError = error as? PipelineError {
                        switch pipelineError {
                        case .taskRunning:
                            retryCount += 1
                            if retryCount > PipelineConstants.maxPollingRetries {
                                await updateStatus(.failed, step: node.step, error: "Polling timeout", isFailed: true)
                                isChainCompleted = false
                                return
                            }
                            try? await Task.sleep(nanoseconds: PipelineConstants.pollingInterval)
                            continue
                        case .channelNotFound(let id):
                            await updateStatus(.failed, step: node.step, error: "Channel \(id) not found", isFailed: true)
                            isChainCompleted = false
                            return
                        case .inputMissing(let msg):
                            await updateStatus(.failed, step: node.step, error: "Input missing: \(msg)", isFailed: true)
                            isChainCompleted = false
                            return
                        case .transcodeFailed:
                            await updateStatus(.failed, step: node.step, error: "Transcoding failed", isFailed: true)
                            isChainCompleted = false
                            return
                        case .cloudError(let msg):
                            await updateStatus(.failed, step: node.step, error: "Cloud service error: \(msg)", isFailed: true)
                            isChainCompleted = false
                            return
                        case .taskFailed(let msg):
                            await updateStatus(.failed, step: node.step, error: "Task failed: \(msg)", isFailed: true)
                            isChainCompleted = false
                            return
                        }
                    }
                    
                    if let transcriptionError = error as? TranscriptionError {
                        await updateStatus(.failed, step: node.step, error: "Transcription Error: \(transcriptionError.localizedDescription)", isFailed: true)
                        isChainCompleted = false
                        return
                    }
                    
                    await updateStatus(.failed, step: node.step, error: error.localizedDescription, isFailed: true)
                    isChainCompleted = false
                    return
                }
            }
        }
        
        await MainActor.run { self.isProcessing = false }
        
        if isChainCompleted && settings.enableEmailNotification && task.status == .completed {
            await sendEmailNotification()
        }
    }
    
    private func sendEmailNotification() async {
        await MainActor.run { self.isProcessing = true }
        
        var attachmentPaths: [String] = []
        var tempFiles: [URL] = []
        let baseFilename = task.safeFilename()
        
        // Prepare summary attachment
        if settings.emailAttachSummary {
            var mdContent = task.markdownSummary()
            if settings.emailAttachAudio {
                var links: [String] = []
                if let url = task.ossUrl { links.append("- Processed: \(url)") }
                if let url = task.originalOssUrl { links.append("- Original: \(url)") }
                if let url = task.outputMp3Path { links.append("- MP3: \(url)") }
                if !links.isEmpty {
                    mdContent += "## Audio Links\n"
                    mdContent += links.joined(separator: "\n")
                    mdContent += "\n\n"
                }
            }
            let mdFilename = baseFilename.appending(".md")
            let mdUrl = FileManager.default.temporaryDirectory.appendingPathComponent(mdFilename)
            if let mdData = mdContent.data(using: .utf8) {
                try? mdData.write(to: mdUrl)
                tempFiles.append(mdUrl)
                attachmentPaths.append(mdUrl.path)
            }
        }
        
        // Prepare transcript attachment
        if settings.emailAttachTranscript, let transcriptText = task.derivedTranscriptText() {
            let transcriptFilename = baseFilename.appending("-transcript.txt")
            let transcriptUrl = FileManager.default.temporaryDirectory.appendingPathComponent(transcriptFilename)
            if let transcriptData = transcriptText.data(using: .utf8) {
                try? transcriptData.write(to: transcriptUrl)
                tempFiles.append(transcriptUrl)
                attachmentPaths.append(transcriptUrl.path)
            }
        }
        
        // Prepare raw data attachment
        if settings.emailAttachRawData {
            if let rawDataStr = task.rawData {
                let rawFilename = baseFilename.appending("-raw.json")
                let rawUrl = FileManager.default.temporaryDirectory.appendingPathComponent(rawFilename)
                if let rawData = rawDataStr.data(using: .utf8) {
                    try? rawData.write(to: rawUrl)
                    tempFiles.append(rawUrl)
                    attachmentPaths.append(rawUrl.path)
                }
            }
        }
        
        do {
            let emailService = EmailService(settings: settings)
            let paths = attachmentPaths.isEmpty ? nil : attachmentPaths
            try await emailService.sendEmail(
                subject: "Meeting Summary: \(task.title)",
                body: "Please find the attached meeting content.",
                attachmentPaths: paths
            )
            settings.log("Email sent successfully to \(settings.recipientEmail)")
        } catch {
            settings.log("Failed to send email: \(error.localizedDescription)")
            await MainActor.run {
                self.errorMessage = "Email failed: \(error.localizedDescription)"
            }
        }
        
        // Clean up temporary files
        for tempFile in tempFiles {
            try? FileManager.default.removeItem(at: tempFile)
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
            config: config
        )
        
        // Hydrate Mixed Channel (0)
        var mixed = ChannelData()
        
        if let rawPath = task.rawLocalFilePath, !rawPath.isEmpty {
            mixed.rawAudioPath = rawPath
        }
        
        let path = task.localFilePath
        if !path.isEmpty {
            if path.hasSuffix("_48k.m4a") {
                mixed.processedAudioPath = path
            } else if mixed.rawAudioPath == nil {
                mixed.rawAudioPath = path
            }
        }
        
        if let rawPath = mixed.rawAudioPath, !rawPath.isEmpty, mixed.processedAudioPath == nil {
            let url = URL(fileURLWithPath: rawPath)
            let inputFilename = url.deletingPathExtension().lastPathComponent
            
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let timestamp = formatter.string(from: task.createdAt)
            
            let timestampedFilename: String
            if inputFilename.contains(timestamp) {
                timestampedFilename = "\(inputFilename)_48k.m4a"
            } else {
                timestampedFilename = "\(inputFilename)-\(timestamp)_48k.m4a"
            }
            let timestampedUrl = url.deletingLastPathComponent().appendingPathComponent(timestampedFilename)
            
            let newProcessedFilename = "\(inputFilename)_48k.m4a"
            let newProcessedUrl = url.deletingLastPathComponent().appendingPathComponent(newProcessedFilename)
            
            if FileManager.default.fileExists(atPath: timestampedUrl.path) {
                mixed.processedAudioPath = timestampedUrl.path
            } else if FileManager.default.fileExists(atPath: newProcessedUrl.path) {
                mixed.processedAudioPath = newProcessedUrl.path
            } else {
                let legacyProcessedFilename = "mixed_48k.m4a"
                let legacyProcessedUrl = url.deletingLastPathComponent().appendingPathComponent(legacyProcessedFilename)
                if FileManager.default.fileExists(atPath: legacyProcessedUrl.path) {
                    mixed.processedAudioPath = legacyProcessedUrl.path
                }
            }
        }
        
        mixed.rawAudioOssURL = task.originalOssUrl
        mixed.processedAudioOssURL = task.ossUrl
        mixed.transcriptionTaskId = task.transcriptionTaskId
        mixed.taskKey = task.taskKey
        mixed.bizDuration = task.bizDuration
        board.channels[0] = mixed
        
        return board
    }
    
    private func persistState(from board: PipelineBoard, channelId: Int, completedStep: MeetingTaskStatus) async {
        guard let channel = board.channels[channelId] else { return }
        
        await MainActor.run {
            updateChannelFields(channel: channel)
            updateChannelStatus(completedStep: completedStep)
            self.errorMessage = nil
        }
        await self.save()
    }
    
    private func updateChannelFields(channel: ChannelData) {
        if let url = channel.rawAudioOssURL { self.task.originalOssUrl = url }
        if let path = channel.rawAudioPath { self.task.rawLocalFilePath = path }
        if let path = channel.processedAudioPath { self.task.localFilePath = path }
        if let url = channel.processedAudioOssURL { self.task.ossUrl = url }
        if let tid = channel.transcriptionTaskId { self.task.transcriptionTaskId = tid }
        if let key = channel.taskKey { self.task.taskKey = key }
        if let dur = channel.bizDuration { self.task.bizDuration = dur }
        if let res = channel.transcript {
            self.task.transcript = res.text
            if let sum = res.summary { self.task.summary = sum }
        }
        // Save complete poll results to database
        if let overview = channel.overviewData {
            self.task.overviewData = overview
            
            // Extract metadata from overview data
            if let data = overview.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                
                // 1. Summary (Fallback if not in result)
                if self.task.summary == nil,
                   let summaryObj = json["Summarization"] as? [String: Any],
                   let text = summaryObj["ParagraphSummary"] as? String {
                    self.task.summary = text
                }
                
                // 2. Meeting Assistance
                if let assistance = json["MeetingAssistance"] as? [String: Any] {
                    // Key Points
                    if self.task.keyPoints == nil,
                       let keyInfo = assistance["KeyInformation"] as? [[String: Any]] {
                        let text = keyInfo.compactMap { item -> String? in
                            let key = item["Key"] as? String ?? item["Name"] as? String
                            let value = item["Value"] as? String ?? item["Content"] as? String
                            if let k = key, let v = value { return "- **\(k)**: \(v)" }
                            if let v = value { return "- \(v)" }
                            return nil
                        }.joined(separator: "\n")
                        if !text.isEmpty { self.task.keyPoints = text }
                    }
                    
                    // Action Items
                    if self.task.actionItems == nil,
                       let actions = assistance["Actions"] as? [[String: Any]] {
                        let text = actions.compactMap { item -> String? in
                            let desc = item["Description"] as? String ?? item["Content"] as? String
                            if let d = desc { return "- [ ] \(d)" }
                            return nil
                        }.joined(separator: "\n")
                        if !text.isEmpty { self.task.actionItems = text }
                    }
                }
            }
        }
        if let transcript = channel.transcriptData { self.task.transcriptData = transcript }
        if let raw = channel.rawData { self.task.rawData = raw }
    }
    
    private func updateChannelStatus(completedStep: MeetingTaskStatus) {
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
        
        if let status = postStatus {
            self.task.status = status
        }
    }
    
    // MARK: - Helpers
    
    private func updateStatus(_ status: MeetingTaskStatus, step: MeetingTaskStatus? = nil, error: String? = nil, isFailed: Bool = false) async {
        await MainActor.run {
            if isFailed {
                self.task.status = .failed
                self.task.failedStep = step
                self.task.lastError = error
                self.errorMessage = error
                self.isProcessing = false
            } else {
                self.task.status = status
                self.errorMessage = nil
            }
        }
        await self.save()
    }

    private func formatTranscriptionError(_ error: TranscriptionError) -> String {
        if let description = error.errorDescription, let suggestion = error.recoverySuggestion {
            return "\(description). \(suggestion)"
        }
        return error.errorDescription ?? error.localizedDescription
    }
    
    // MARK: - Legacy Support for Tests
    
    func buildTranscriptText(from transcriptionData: [String: Any]) -> String {
        return TranscriptParser.buildTranscriptText(from: transcriptionData) ?? ""
    }
    
    private func save() async {
        let snapshot = await MainActor.run { self.task }
        let providerType = String(describing: type(of: StorageManager.shared.currentProvider))
        settings.log("MeetingPipelineManager save() called. TaskID: \(snapshot.id), Status: \(snapshot.status.rawValue), Provider: \(providerType)")
        
        do {
            try await StorageManager.shared.currentProvider.saveTask(snapshot)
            settings.log("MeetingPipelineManager save() success")
        } catch {
            settings.log("MeetingPipelineManager save() failed: \(error)")
        }
        
        NotificationCenter.default.post(name: .meetingTaskDidUpdate, object: snapshot.id, userInfo: [MeetingTask.userInfoTaskKey: snapshot])
    }
}
