import SwiftUI

struct PipelineStepDescriptor: Identifiable {
    let id: MeetingTaskStatus
    let title: String
    let icon: String
    let isInteractive: Bool
    let isAlwaysCompleted: Bool
}

struct PipelineView: View {
    @StateObject var manager: MeetingPipelineManager
    private let settings: SettingsStore
    @State private var showingResult = false
    
    @State private var stepToRerun: MeetingTaskStatus?
    @State private var showRerunAlert = false
    
    init(task: MeetingTask, settings: SettingsStore) {
        self.settings = settings
        _manager = StateObject(wrappedValue: MeetingPipelineManager(task: task, settings: settings))
    }
    
    // MARK: - Configuration
    
    private var pipelineSteps: [PipelineStepDescriptor] {
        [
            .init(id: .recorded, title: "Record", icon: "mic.fill", isInteractive: false, isAlwaysCompleted: true),
            .init(id: .uploadingRaw, title: "Upload Raw", icon: "arrow.up.doc.fill", isInteractive: true, isAlwaysCompleted: false),
            .init(id: .transcoding, title: "Transcode", icon: "waveform", isInteractive: true, isAlwaysCompleted: false),
            .init(id: .uploading, title: "Upload", icon: "icloud.and.arrow.up.fill", isInteractive: true, isAlwaysCompleted: false),
            .init(id: .created, title: "Create Task", icon: "doc.badge.plus", isInteractive: true, isAlwaysCompleted: false),
            .init(id: .polling, title: "Poll", icon: "arrow.triangle.2.circlepath", isInteractive: true, isAlwaysCompleted: false)
        ]
    }
    
    private let fullOrder: [MeetingTaskStatus] = [
        .recorded, .uploadingRaw, .uploadedRaw, .transcoding, .transcoded, .uploading, .uploaded, .created, .polling, .completed
    ]

    var body: some View {
        VStack(spacing: 32) {
            HStack(spacing: 0) {
                ForEach(Array(pipelineSteps.enumerated()), id: \.element.id) { index, step in
                    stepButton(for: step)
                    
                    if index < pipelineSteps.count - 1 {
                        ArrowView()
                    }
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .cornerRadius(16)
            
            if manager.task.mode == .separated {
                SeparatedStatusView(task: manager.task) { speakerId in
                    Task { await manager.retry(speaker: speakerId) }
                }
            }
            
            VStack(spacing: 16) {
                if let error = manager.errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(error)
                    }
                    .foregroundColor(.red)
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                }
                
                if manager.isProcessing {
                    ProgressView("Processing...")
                        .controlSize(.large)
                } else {
                    actionButton
                        .controlSize(.large)
                }
            }
            
            if manager.task.status == .completed {
                Button(action: {
                    showingResult = true
                }) {
                    HStack {
                        Text("View Result")
                        Image(systemName: "chevron.right")
                    }
                    .frame(maxWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showingResult) {
            ResultView(task: manager.task, settings: settings)
        }
        .alert("Rerun Step?", isPresented: $showRerunAlert, presenting: stepToRerun) { step in
            Button("Cancel", role: .cancel) { }
            Button("Rerun") {
                rerun(step)
            }
        } message: { step in
            Text("Rerun '\(stepTitle(step))'? Cached artifacts for this step will be cleared.")
        }
    }
    
    @ViewBuilder
    private func stepButton(for descriptor: PipelineStepDescriptor) -> some View {
        let canRerun = (manager.task.status == .completed || manager.task.status == .failed) && descriptor.isInteractive
        
        if canRerun {
            Button(action: {
                stepToRerun = descriptor.id
                showRerunAlert = true
            }) {
                StepView(
                    title: descriptor.title,
                    icon: descriptor.icon,
                    isActive: isStepActive(descriptor.id),
                    isCompleted: descriptor.isAlwaysCompleted || isAfter(descriptor.id),
                    isFailed: isFailed(descriptor.id)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .help("Click to rerun this step")
        } else {
            StepView(
                title: descriptor.title,
                icon: descriptor.icon,
                isActive: isStepActive(descriptor.id),
                isCompleted: descriptor.isAlwaysCompleted || isAfter(descriptor.id),
                isFailed: isFailed(descriptor.id)
            )
        }
    }
    
    private func stepTitle(_ step: MeetingTaskStatus) -> String {
        pipelineSteps.first(where: { $0.id == step })?.title ?? step.rawValue
    }

    private func rerun(_ step: MeetingTaskStatus) {
        Task {
            await manager.prepareForRerun(step: step)
            switch step {
            case .uploadingRaw: await manager.uploadOriginal()
            case .transcoding: await manager.transcode(force: true)
            case .uploading: await manager.upload()
            case .created: await manager.createTask()
            case .polling: await manager.pollStatus()
            default: break
            }
        }
    }
    
    private func isAfter(_ status: MeetingTaskStatus) -> Bool {
        let currentStatus: MeetingTaskStatus
        if manager.task.status == .failed {
            if let failedStep = manager.task.failedStep {
                currentStatus = failedStep
            } else {
                return false
            }
        } else {
            currentStatus = manager.task.status
        }
        
        // Special case: .created status means Create Task step is completed
        if currentStatus == .created && status == .created { return true }
        
        guard let currentIndex = fullOrder.firstIndex(of: currentStatus),
              let targetIndex = fullOrder.firstIndex(of: status) else { return false }
        
        return currentIndex > targetIndex
    }
    
    private func isStepActive(_ step: MeetingTaskStatus) -> Bool {
        // 1. Exactly matching status (Running)
        if manager.task.status == step { return true }
        
        // 2. Waiting for next step (Manual mode readiness)
        switch (manager.task.status, step) {
        case (.recorded, .uploadingRaw): return true
        case (.uploadedRaw, .transcoding): return true
        case (.transcoded, .uploading): return true
        case (.uploaded, .created): return true
        case (.created, .polling): return true
        default: return false
        }
    }
    
    private func isFailed(_ step: MeetingTaskStatus) -> Bool {
        guard manager.task.status == .failed else { return false }
        if manager.task.mode == .separated {
            return manager.task.speaker1FailedStep == step || manager.task.speaker2FailedStep == step
        }
        return manager.task.failedStep == step
    }
    
    @ViewBuilder
    private var actionButton: some View {
        switch manager.task.status {
        case .recorded:
            Button("Start Processing") {
                Task { await manager.uploadOriginal() }
            }
            .buttonStyle(.borderedProminent)
            
        case .failed:
            VStack {
                if manager.task.mode == .mixed {
                    if let failedStep = manager.task.failedStep {
                        Text("Failed at: \(failedStep.displayName)")
                            .foregroundColor(.red)
                            .font(.caption)
                        
                        Button("Retry \(failedStep.displayName)") {
                            Task { await manager.retry() }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Retry Last Step") {
                            Task { await manager.retry() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    if manager.task.speaker1Status == .failed || manager.task.speaker2Status == .failed {
                         Text("Check individual speakers above")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    } else {
                         Button("Retry Last Step") {
                             Task { await manager.retry() }
                         }
                         .buttonStyle(.borderedProminent)
                    }
                }
                
                Button("Restart from Beginning") {
                    Task { await manager.restartFromBeginning() }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .font(.caption)
                .padding(.top, 4)
            }
            
        case .uploadingRaw:
            Text("Uploading Original...")
            
        case .uploadedRaw:
            Button("Start Transcode") {
                Task { await manager.transcode() }
            }
            .buttonStyle(.borderedProminent)
            
        case .transcoding:
            Text("Transcoding...")
            
        case .transcoded:
            Button("Upload to OSS") {
                Task { await manager.upload() }
            }
            .buttonStyle(.borderedProminent)
            
        case .uploading:
            Text("Uploading...")
            
        case .uploaded:
             Button("Create Tingwu Task") {
                 Task { await manager.createTask() }
             }
             .buttonStyle(.borderedProminent)
             
        case .created:
             Button("Start Polling") {
                 Task { await manager.pollStatus() }
             }
             .buttonStyle(.bordered)
             
        case .polling:
             Button("Refresh Status") {
                 Task { await manager.pollStatus() }
             }
             .buttonStyle(.bordered)
             
        case .completed:
             Text("Completed")
                .foregroundColor(.green)
        }
    }
}

struct SeparatedStatusView: View {
    let task: MeetingTask
    let onRetry: (Int) -> Void
    
    var body: some View {
        HStack(spacing: 40) {
            SpeakerStatusItem(
                name: "Speaker 1 (Local)",
                status: task.speaker1Status,
                failedStep: task.speaker1FailedStep,
                globalStatus: task.status,
                onRetry: { onRetry(1) }
            )
            
            SpeakerStatusItem(
                name: "Speaker 2 (Remote)",
                status: task.speaker2Status,
                failedStep: task.speaker2FailedStep,
                globalStatus: task.status,
                onRetry: { onRetry(2) }
            )
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
}

struct SpeakerStatusItem: View {
    let name: String
    let status: MeetingTaskStatus?
    let failedStep: MeetingTaskStatus?
    let globalStatus: MeetingTaskStatus
    let onRetry: () -> Void
    
    var displayStatus: String {
        if let status = status {
            return status.displayName
        }
        if globalStatus == .polling {
            return "Pending..."
        }
        return globalStatus.displayName
    }
    
    var statusColor: Color {
        if let status = status {
            switch status {
            case .completed: return .green
            case .failed: return .red
            default: return .orange
            }
        }
        switch globalStatus {
        case .completed: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                
                Text(displayStatus)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                
                if status == .failed {
                    Button(action: onRetry) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Retry this speaker")
                }
            }
            
            if let step = failedStep {
                Text("Failed at: \(step.displayName)")
                    .font(.caption2)
                    .foregroundColor(.red)
            }
        }
        .frame(minWidth: 120, alignment: .leading)
    }
}

struct StepView: View {
    let title: String
    let icon: String
    let isActive: Bool
    let isCompleted: Bool
    let isFailed: Bool
    
    var body: some View {
        VStack {
            Image(systemName: icon)
            .font(.title2)
            .foregroundColor(foregroundOrigin)
            .frame(width: 40, height: 40)
            .background(Circle().fill(backgroundOrigin))
            
            Text(title)
                .font(.caption)
                .foregroundColor(textOrigin)
        }
        .frame(width: 80)
    }
    
    private var foregroundOrigin: Color {
        if isFailed { return .red }
        if isCompleted { return .green }
        if isActive { return .blue }
        return .gray
    }
    
    private var backgroundOrigin: Color {
        if isFailed { return Color.red.opacity(0.1) }
        if isCompleted { return Color.green.opacity(0.1) }
        if isActive { return Color.blue.opacity(0.1) }
        return Color.gray.opacity(0.1)
    }
    
    private var textOrigin: Color {
        if isFailed { return .red }
        if isCompleted { return .primary }
        if isActive { return .blue }
        return .secondary
    }
}

struct ArrowView: View {
    var body: some View {
        Image(systemName: "arrow.right")
            .foregroundColor(.gray)
            .frame(width: 20)
    }
}
