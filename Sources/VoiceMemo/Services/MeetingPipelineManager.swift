import Foundation
import AVFoundation
import Combine

class MeetingPipelineManager: ObservableObject {
    @Published var task: MeetingTask
    @Published var isProcessing: Bool = false
    @Published var errorMessage: String?
    
    private let ossService: OSSService
    private let tingwuService: TingwuService
    private let database: DatabaseManager
    private let settings: SettingsStore
    
    init(task: MeetingTask, settings: SettingsStore) {
        self.task = task
        self.settings = settings
        self.ossService = OSSService(settings: settings)
        self.tingwuService = TingwuService(settings: settings)
        self.database = DatabaseManager.shared
    }
    
    // MARK: - Actions
    
    func transcode(force: Bool = false) async {
        if !force {
            guard task.status == .recorded || task.status == .failed else { return }
        }
        
        settings.log("Transcode start: input=\(task.localFilePath) mode=\(task.mode)")
        await updateStatus(.transcoding, error: nil)
        
        if task.mode == .mixed {
            let inputURL = URL(fileURLWithPath: task.localFilePath)
            let outputURL = inputURL.deletingLastPathComponent().appendingPathComponent("mixed_48k.m4a")
            
            if await performTranscode(input: inputURL, output: outputURL) {
                var updatedTask = task
                updatedTask.localFilePath = outputURL.path
                self.task.localFilePath = outputURL.path
                self.task = updatedTask // Update published task
                settings.log("Transcode success: output=\(outputURL.path)")
                await updateStatus(.transcoded, error: nil)
            } else {
                await updateStatus(.failed, step: .transcoding, error: "Transcode failed")
            }
        } else {
            // Separated Mode
            guard let p1 = task.speaker1AudioPath, let p2 = task.speaker2AudioPath else {
                await updateStatus(.failed, step: .transcoding, error: "Missing speaker audio paths")
                return
            }
            
            let url1 = URL(fileURLWithPath: p1)
            let url2 = URL(fileURLWithPath: p2)
            let out1 = url1.deletingLastPathComponent().appendingPathComponent("speaker1_48k.m4a")
            let out2 = url2.deletingLastPathComponent().appendingPathComponent("speaker2_48k.m4a")
            
            async let t1 = performTranscode(input: url1, output: out1)
            async let t2 = performTranscode(input: url2, output: out2)
            
            let (r1, r2) = await (t1, t2)
            
            if r1 && r2 {
                var updatedTask = task
                updatedTask.speaker1AudioPath = out1.path
                updatedTask.speaker2AudioPath = out2.path
                updatedTask.localFilePath = out1.path // Keep localFilePath valid as primary
                self.task = updatedTask
                settings.log("Transcode success: spk1=\(out1.path) spk2=\(out2.path)")
                await updateStatus(.transcoded, error: nil)
            } else {
                await updateStatus(.failed, step: .transcoding, error: "Transcode failed for one or both channels")
            }
        }
    }
    
    private func performTranscode(input: URL, output: URL) async -> Bool {
        try? FileManager.default.removeItem(at: output)
        
        // Basic check if input file exists and has content
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: input.path)
            if let size = attrs[.size] as? UInt64, size == 0 {
                settings.log("Transcode failed: Input file \(input.lastPathComponent) is empty (0 bytes)")
                return false
            }
        } catch {
            settings.log("Transcode failed: Cannot access input file \(input.lastPathComponent): \(error.localizedDescription)")
            return false
        }

        let asset = AVAsset(url: input)
        
        // Check if asset is readable
        do {
            let isReadable = try await asset.load(.isReadable)
            if !isReadable {
                settings.log("Transcode failed: Input file \(input.lastPathComponent) is not readable by AVAsset")
                return false
            }
        } catch {
            settings.log("Transcode failed: Failed to load asset metadata for \(input.lastPathComponent): \(error.localizedDescription)")
            return false
        }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            settings.log("Transcode failed: cannot create export session for \(input.lastPathComponent)")
            return false
        }
        
        exportSession.outputURL = output
        exportSession.outputFileType = .m4a
        await exportSession.export()
        
        if exportSession.status == .completed {
            return true
        } else {
            let err = exportSession.error?.localizedDescription ?? "Unknown error"
            settings.log("Transcode failed for \(input.lastPathComponent): \(err)")
            return false
        }
    }
    
    func upload() async {
        settings.log("Upload start: mode=\(task.mode)")
        await updateStatus(.uploading, error: nil)
        
        do {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy/MM/dd"
            let datePath = formatter.string(from: task.createdAt)
            
            if task.mode == .mixed {
                let fileURL = URL(fileURLWithPath: task.localFilePath)
                let objectKey = "\(settings.ossPrefix)\(datePath)/\(task.recordingId)/mixed.m4a"
                
                let url = try await ossService.uploadFile(fileURL: fileURL, objectKey: objectKey)
                
                var updatedTask = task
                updatedTask.ossUrl = url
                updatedTask.status = .uploaded // Ready to create task
                self.task = updatedTask
                self.save()
                settings.log("Upload success: url=\(url)")
            } else {
                guard let p1 = task.speaker1AudioPath, let p2 = task.speaker2AudioPath else {
                    throw NSError(domain: "Pipeline", code: 404, userInfo: [NSLocalizedDescriptionKey: "Missing speaker paths"])
                }
                
                let u1 = URL(fileURLWithPath: p1)
                let u2 = URL(fileURLWithPath: p2)
                let key1 = "\(settings.ossPrefix)\(datePath)/\(task.recordingId)/speaker1.m4a"
                let key2 = "\(settings.ossPrefix)\(datePath)/\(task.recordingId)/speaker2.m4a"
                
                async let upload1 = ossService.uploadFile(fileURL: u1, objectKey: key1)
                async let upload2 = ossService.uploadFile(fileURL: u2, objectKey: key2)
                
                let (url1, url2) = try await (upload1, upload2)
                
                var updatedTask = task
                updatedTask.ossUrl = url1
                updatedTask.speaker2OssUrl = url2
                updatedTask.status = .uploaded
                self.task = updatedTask
                self.save()
                settings.log("Upload success: url1=\(url1) url2=\(url2)")
            }
        } catch {
            settings.log("Upload failed: \(error.localizedDescription)")
            await updateStatus(.failed, step: .uploading, error: error.localizedDescription)
        }
    }
    
    func createTask() async {
        guard let ossUrl = task.ossUrl else { return }
        settings.log("Create task start: mode=\(task.mode)")
        await updateStatus(.created, error: nil) // Using created as "Creating..." (transient)
        
        do {
            if task.mode == .mixed {
                let taskId = try await tingwuService.createTask(fileUrl: ossUrl)
                
                var updatedTask = task
                updatedTask.tingwuTaskId = taskId
                updatedTask.status = .polling // Ready to poll
                self.task = updatedTask
                self.save()
                settings.log("Create task success: taskId=\(taskId)")
            } else {
                guard let url2 = task.speaker2OssUrl else {
                    throw NSError(domain: "Pipeline", code: 404, userInfo: [NSLocalizedDescriptionKey: "Missing speaker 2 url"])
                }
                
                async let t1 = tingwuService.createTask(fileUrl: ossUrl)
                async let t2 = tingwuService.createTask(fileUrl: url2)
                
                let (id1, id2) = try await (t1, t2)
                
                var updatedTask = task
                updatedTask.tingwuTaskId = id1
                updatedTask.speaker2TingwuTaskId = id2
                updatedTask.status = .polling
                self.task = updatedTask
                self.save()
                settings.log("Create task success: id1=\(id1) id2=\(id2)")
            }
        } catch {
             settings.log("Create task failed: \(error.localizedDescription)")
             await updateStatus(.failed, step: .created, error: error.localizedDescription)
        }
    }
    
    func pollStatus() async {
        if task.mode == .mixed {
            await pollMixedStatus()
        } else {
            await pollSeparatedStatus()
        }
    }

    func pollMixedStatus() async {
        guard let taskId = task.tingwuTaskId else { return }
        settings.log("Poll status start: taskId=\(taskId)")
        await MainActor.run { self.isProcessing = true }
        
        do {
            let (status, data) = try await tingwuService.getTaskInfo(taskId: taskId)
            settings.log("Poll status: \(status)")
            
            if status == "SUCCESS" || status == "COMPLETED" {
                if let result = data?["Result"] as? [String: Any] {
                    var updatedTask = task
                    updatedTask.status = .completed
                    
                    // Extract Metadata
                    if let taskKey = data?["TaskKey"] as? String { updatedTask.taskKey = taskKey }
                    if let taskStatus = data?["TaskStatus"] as? String { updatedTask.apiStatus = taskStatus }
                    if let statusText = data?["StatusText"] as? String { updatedTask.statusText = statusText }
                    if let bizDuration = data?["BizDuration"] as? Int { updatedTask.bizDuration = bizDuration }
                    if let outputMp3Path = result["OutputMp3Path"] as? String { updatedTask.outputMp3Path = outputMp3Path }
                    
                    if let jsonData = try? JSONSerialization.data(withJSONObject: data!, options: .prettyPrinted) {
                        updatedTask.rawResponse = String(data: jsonData, encoding: .utf8)
                    }
                    
                    if let transcriptText = await fetchTranscript(from: result) {
                        updatedTask.transcript = transcriptText
                    }
                    
                    // 2. Handle Summarization
                    if let summarizationUrl = result["Summarization"] as? String {
                        if let summarizationData = try? await tingwuService.fetchJSON(url: summarizationUrl) {
                            if let summarizationObj = summarizationData["Summarization"] as? [String: Any] {
                                // Handle new structure inside "Summarization" key
                                if let summary = summarizationObj["ParagraphTitle"] as? String {
                                    updatedTask.summary = summary
                                }
                                if let summaryText = summarizationObj["ParagraphSummary"] as? String {
                                    updatedTask.summary = (updatedTask.summary ?? "") + "\n\n" + summaryText
                                }
                                
                                // Conversational Summary
                                if let conversationalSummary = summarizationObj["ConversationalSummary"] as? [[String: Any]] {
                                    let convText = conversationalSummary.compactMap { item -> String? in
                                        guard let speaker = item["SpeakerName"] as? String,
                                              let summary = item["Summary"] as? String else { return nil }
                                        return "\(speaker): \(summary)"
                                    }.joined(separator: "\n\n")
                                    if !convText.isEmpty {
                                        updatedTask.summary = (updatedTask.summary ?? "") + "\n\n### 对话总结\n" + convText
                                    }
                                }
                                
                                // Q&A Summary
                                if let qaSummary = summarizationObj["QuestionsAnsweringSummary"] as? [[String: Any]] {
                                    let qaText = qaSummary.compactMap { item -> String? in
                                        guard let q = item["Question"] as? String,
                                              let a = item["Answer"] as? String else { return nil }
                                        return "Q: \(q)\nA: \(a)"
                                    }.joined(separator: "\n\n")
                                    if !qaText.isEmpty {
                                        updatedTask.summary = (updatedTask.summary ?? "") + "\n\n### 问答总结\n" + qaText
                                    }
                                }
                                
                                // MindMap
                                if let mindMapSummary = summarizationObj["MindMapSummary"] as? [[String: Any]] {
                                    // Simple recursive extraction for mind map could be complex, for now just dump title
                                    let mmText = mindMapSummary.compactMap { $0["Title"] as? String }.joined(separator: ", ")
                                    if !mmText.isEmpty {
                                        updatedTask.summary = (updatedTask.summary ?? "") + "\n\n### 思维导图主题\n" + mmText
                                    }
                                }
                            } else {
                                // Fallback to old flat structure if any
                                if let summary = summarizationData["Headline"] as? String {
                                    updatedTask.summary = summary
                                }
                                if let summaryText = summarizationData["Summary"] as? String {
                                    updatedTask.summary = (updatedTask.summary ?? "") + "\n\n" + summaryText
                                }
                            }
                        }
                    } else if let summaryObj = result["Summarization"] as? [String: Any] {
                        // Fallback to inline Summarization if present
                        if let summary = summaryObj["Headline"] as? String {
                            updatedTask.summary = summary
                        }
                        if let summaryText = summaryObj["Summary"] as? String {
                            updatedTask.summary = (updatedTask.summary ?? "") + "\n\n" + summaryText
                        }
                        
                        if let keyPointsList = summaryObj["KeyPoints"] as? [[String: Any]] {
                            let kpText = keyPointsList.compactMap { $0["Text"] as? String }.joined(separator: "\n- ")
                            updatedTask.keyPoints = "- " + kpText
                        }
                        
                        if let actionItemsList = summaryObj["ActionItems"] as? [[String: Any]] {
                            let aiText = actionItemsList.compactMap { $0["Text"] as? String }.joined(separator: "\n- ")
                            updatedTask.actionItems = "- " + aiText
                        }
                    }
                    
                    // 3. Handle MeetingAssistance (KeyPoints/Actions might also be here)
                    if let assistanceUrl = result["MeetingAssistance"] as? String {
                        if let assistanceData = try? await tingwuService.fetchJSON(url: assistanceUrl) {
                            if let assistanceObj = assistanceData["MeetingAssistance"] as? [String: Any] {
                                // Handle Keywords
                                if let keywords = assistanceObj["Keywords"] as? [String] {
                                    let kwText = keywords.joined(separator: ", ")
                                    updatedTask.keyPoints = (updatedTask.keyPoints ?? "") + "### 关键词\n" + kwText + "\n\n"
                                }
                                
                                // Handle KeySentences (as Key Points)
                                if let keySentences = assistanceObj["KeySentences"] as? [[String: Any]] {
                                    let ksText = keySentences.compactMap { $0["Text"] as? String }.joined(separator: "\n- ")
                                    updatedTask.keyPoints = (updatedTask.keyPoints ?? "") + "### 重点语句\n- " + ksText
                                }
                                
                                // Handle ActionItems (if present in new structure, though logs don't show it yet)
                                if let actionItemsList = assistanceObj["ActionItems"] as? [[String: Any]] {
                                    let aiText = actionItemsList.compactMap { $0["Text"] as? String }.joined(separator: "\n- ")
                                    updatedTask.actionItems = "- " + aiText
                                }
                            } else {
                                // Fallback to flat structure
                                if let keyPointsList = assistanceData["KeyPoints"] as? [[String: Any]], updatedTask.keyPoints == nil {
                                    let kpText = keyPointsList.compactMap { $0["Text"] as? String }.joined(separator: "\n- ")
                                    updatedTask.keyPoints = "- " + kpText
                                }
                                
                                if let actionItemsList = assistanceData["ActionItems"] as? [[String: Any]], updatedTask.actionItems == nil {
                                    let aiText = actionItemsList.compactMap { $0["Text"] as? String }.joined(separator: "\n- ")
                                    updatedTask.actionItems = "- " + aiText
                                }
                            }
                        }
                    }
                    
                    self.task = updatedTask
                    self.save()
                    settings.log("Poll success: results saved")
                }
            } else if status == "FAILED" {
                 settings.log("Poll failed: cloud task failed")
                 
                 // Extract Metadata for failure analysis
                 var updatedTask = task
                 if let data = data {
                     if let taskKey = data["TaskKey"] as? String { updatedTask.taskKey = taskKey }
                     if let taskStatus = data["TaskStatus"] as? String { updatedTask.apiStatus = taskStatus }
                     if let statusText = data["StatusText"] as? String { updatedTask.statusText = statusText }
                 }
                 self.task = updatedTask
                 
                 await updateStatus(.failed, step: .polling, error: "Task failed in cloud: \(self.task.statusText ?? "Unknown error")")
            } else {
                 await MainActor.run { self.isProcessing = false }
            }
        } catch {
            settings.log("Poll failed: \(error.localizedDescription)")
            await updateStatus(.failed, step: .polling, error: error.localizedDescription)
        }
        
        await MainActor.run { self.isProcessing = false }
    }
    
    func pollSeparatedStatus() async {
        guard let id1 = task.tingwuTaskId, let id2 = task.speaker2TingwuTaskId else { return }
        await MainActor.run { self.isProcessing = true }
        
        async let r1 = pollSingleTask(taskId: id1)
        async let r2 = pollSingleTask(taskId: id2)
        
        let (res1, res2) = await (r1, r2)
        
        var updatedTask = task
        var s1Done = false
        var s2Done = false
        var hasFailure = false
        
        // Handle Result 1
        if let (status, data) = res1 {
            if status == "SUCCESS" || status == "COMPLETED" {
                updatedTask.speaker1Status = .completed
                if let result = data?["Result"] as? [String: Any],
                   let transcript = await fetchTranscript(from: result) {
                     updatedTask.speaker1Transcript = transcript
                }
                s1Done = true
            } else if status == "FAILED" {
                updatedTask.speaker1Status = .failed
                hasFailure = true
                s1Done = true
            }
        }
        
        // Handle Result 2
        if let (status, data) = res2 {
            if status == "SUCCESS" || status == "COMPLETED" {
                updatedTask.speaker2Status = .completed
                if let result = data?["Result"] as? [String: Any],
                   let transcript = await fetchTranscript(from: result) {
                     updatedTask.speaker2Transcript = transcript
                }
                s2Done = true
            } else if status == "FAILED" {
                updatedTask.speaker2Status = .failed
                hasFailure = true
                s2Done = true
            }
        }
        
        self.task = updatedTask
        self.save()
        
        if s1Done && s2Done {
             if updatedTask.speaker1Status == .completed || updatedTask.speaker2Status == .completed {
                 // At least one succeeded
                 await alignTranscripts()
                 updatedTask = self.task // Refresh
                 updatedTask.status = .completed
                 if hasFailure {
                     updatedTask.lastError = "Partial success: One speaker failed"
                 }
                 self.task = updatedTask
                 self.save()
             } else {
                 await updateStatus(.failed, step: .polling, error: "Both speakers failed")
             }
        }
        
        await MainActor.run { self.isProcessing = false }
    }
    
    private func pollSingleTask(taskId: String) async -> (String?, [String: Any]?)? {
        do {
            return try await tingwuService.getTaskInfo(taskId: taskId)
        } catch {
            settings.log("Poll single failed: \(error)")
            return nil
        }
    }
    
    private func fetchTranscript(from result: [String: Any]) async -> String? {
        var transcriptText: String?
        if let transcriptionUrl = result["Transcription"] as? String {
            do {
                let transcriptionData = try await tingwuService.fetchJSON(url: transcriptionUrl)
                transcriptText = buildTranscriptText(from: transcriptionData)
            } catch {
                settings.log("Failed to download transcript")
            }
        } else if let transcriptionObj = result["Transcription"] as? [String: Any] {
            transcriptText = buildTranscriptText(from: transcriptionObj)
        }
        
        if transcriptText == nil {
            if let paragraphs = result["Paragraphs"] as? [[String: Any]] {
                transcriptText = buildTranscriptText(from: ["Paragraphs": paragraphs])
            } else if let sentences = result["Sentences"] as? [[String: Any]] {
                transcriptText = buildTranscriptText(from: ["Sentences": sentences])
            } else if let transcriptInline = result["Transcript"] as? String {
                transcriptText = transcriptInline
            }
        }
        return transcriptText
    }
    
    private func alignTranscripts() async {
        // Simple merge for now
        let t1 = task.speaker1Transcript ?? ""
        let t2 = task.speaker2Transcript ?? ""
        var merged = ""
        if !t1.isEmpty { merged += "### Speaker 1 (Local)\n\(t1)\n\n" }
        if !t2.isEmpty { merged += "### Speaker 2 (Remote)\n\(t2)\n" }
        
        var updatedTask = task
        updatedTask.transcript = merged
        // TODO: Implement real alignment logic here to populate alignedConversation
        self.task = updatedTask
        self.save()
    }
    
    func retry() async {
        guard task.status == .failed else { return }
        
        self.task.retryCount += 1
        let step = self.task.failedStep ?? .recorded // Default to start if unknown
        
        settings.log("Retry requested. Count: \(task.retryCount), Step: \(step.rawValue)")
        
        switch step {
        case .transcoding:
            await transcode()
        case .uploading:
            await upload()
        case .created:
            await createTask()
        case .polling:
            await pollStatus()
        default:
            // Fallback: try to determine from last successful status
            if let last = task.lastSuccessfulStatus {
                switch last {
                case .recorded: await transcode()
                case .transcoded: await upload()
                case .uploaded: await createTask()
                case .created: await pollStatus() // Should not happen if created is transient, but just in case
                default: await transcode()
                }
            } else {
                await transcode()
            }
        }
    }
    
    func restartFromBeginning() async {
        settings.log("Restart from beginning requested.")
        
        // Reset fields
        var updatedTask = task
        updatedTask.ossUrl = nil
        updatedTask.tingwuTaskId = nil
        updatedTask.taskKey = nil
        updatedTask.apiStatus = nil
        updatedTask.statusText = nil
        updatedTask.bizDuration = nil
        updatedTask.outputMp3Path = nil
        updatedTask.rawResponse = nil
        updatedTask.transcript = nil
        updatedTask.summary = nil
        updatedTask.keyPoints = nil
        updatedTask.actionItems = nil
        
        updatedTask.status = .recorded
        updatedTask.lastSuccessfulStatus = nil
        updatedTask.failedStep = nil
        updatedTask.lastError = nil
        updatedTask.retryCount += 1
        
        self.task = updatedTask
        self.save()
        self.errorMessage = nil
        
        await transcode()
    }
    
    // MARK: - Helper
    
    @MainActor
    private func updateStatus(_ status: MeetingTaskStatus, step: MeetingTaskStatus? = nil, error: String?) {
        self.task.status = status
        self.task.lastError = error
        self.errorMessage = error
        self.isProcessing = false
        
        if status == .failed {
            if let step = step {
                self.task.failedStep = step
            }
        } else if status != .created {
            // .created is transient, don't mark it as last successful
            self.task.lastSuccessfulStatus = status
        }
        
        settings.log("Task status updated: \(status.rawValue) step=\(step?.rawValue ?? "nil") error=\(error ?? "")")
        self.save()
    }
    
    private func save() {
        database.saveTask(self.task)
    }
    
    func buildTranscriptText(from transcriptionData: [String: Any]) -> String? {
        // Check for nested Result.Transcription
        if let result = transcriptionData["Result"] as? [String: Any],
           let transcription = result["Transcription"] as? [String: Any] {
            return buildTranscriptText(from: transcription)
        }
        
        // Check for nested Transcription
        if let transcription = transcriptionData["Transcription"] as? [String: Any] {
            return buildTranscriptText(from: transcription)
        }

        if let paragraphs = transcriptionData["Paragraphs"] as? [[String: Any]] {
            let lines = paragraphs.compactMap { paragraph -> String? in
                let speaker = extractSpeaker(from: paragraph)
                let text = extractText(from: paragraph)
                guard !text.isEmpty else { return nil }
                if let speaker {
                    return "\(speaker): \(text)"
                }
                return text
            }
            return lines.joined(separator: "\n")
        }
        
        if let sentences = transcriptionData["Sentences"] as? [[String: Any]] {
            let lines = sentences.compactMap { sentence -> String? in
                let speaker = extractSpeaker(from: sentence)
                let text = extractText(from: sentence)
                guard !text.isEmpty else { return nil }
                if let speaker {
                    return "\(speaker): \(text)"
                }
                return text
            }
            return lines.joined(separator: "\n")
        }
        
        if let transcript = transcriptionData["Transcript"] as? String {
            return transcript
        }
        
        return nil
    }
    
    private func extractText(from item: [String: Any]) -> String {
        if let text = item["Text"] as? String, !text.isEmpty {
            return text
        }
        if let text = item["text"] as? String, !text.isEmpty {
            return text
        }
        if let words = item["Words"] as? [[String: Any]] {
            let wordTexts = words.compactMap { word -> String? in
                if let text = word["Text"] as? String, !text.isEmpty {
                    return text
                }
                if let text = word["text"] as? String, !text.isEmpty {
                    return text
                }
                return nil
            }
            return wordTexts.joined()
        }
        if let words = item["Words"] as? [String] {
            return words.joined()
        }
        return ""
    }
    
    private func extractSpeaker(from item: [String: Any]) -> String? {
        if let name = item["SpeakerName"] as? String, !name.isEmpty {
            return name
        }
        if let name = item["Speaker"] as? String, !name.isEmpty {
            return name
        }
        if let name = item["Role"] as? String, !name.isEmpty {
            return name
        }
        if let id = item["SpeakerId"] {
            return "Speaker \(stringify(id))"
        }
        if let id = item["SpeakerID"] {
            return "Speaker \(stringify(id))"
        }
        if let id = item["RoleId"] {
            return "Speaker \(stringify(id))"
        }
        return nil
    }
    
    private func stringify(_ value: Any) -> String {
        if let str = value as? String {
            return str
        }
        if let num = value as? Int {
            return String(num)
        }
        if let num = value as? Double {
            return String(Int(num))
        }
        return "\(value)"
    }
}
