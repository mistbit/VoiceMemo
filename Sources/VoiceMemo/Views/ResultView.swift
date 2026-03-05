import SwiftUI
import UniformTypeIdentifiers

struct ResultView: View {
    let task: MeetingTask
    let settings: SettingsStore
    @ObservedObject var playback: AudioPlaybackController
    @State private var selectedTab: ResultTab = .overview
    @State private var isSendingEmail = false
    @State private var emailStatus: String?
    @Namespace private var animationNamespace
    
    enum ResultTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case transcript = "Transcript"
        case raw = "Raw Data"
        case pipeline = "Pipeline"
        
        var id: String { self.rawValue }
    }
    
    init(task: MeetingTask, settings: SettingsStore, playback: AudioPlaybackController) {
        self.task = task
        self.settings = settings
        self.playback = playback
        // Default to Pipeline if task is not completed
        if task.status != .completed {
            _selectedTab = State(initialValue: .pipeline)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 16) {
                // Top Row: Title & Actions
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title)
                            .font(.title2)
                            .fontWeight(.bold)
                        Text(task.createdAt, style: .date)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    if settings.enableEmailNotification {
                        let isCompleted = task.status == .completed
                        Button(action: {
                            Task { await sendEmail() }
                        }) {
                            HStack(spacing: 4) {
                                if isSendingEmail {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "envelope")
                                }
                                Text(emailStatus ?? "Email")
                            }
                        }
                        .disabled(isSendingEmail || !isCompleted)
                        .help({
                            if isCompleted {
                                return "Send meeting summary via email"
                            }
                            if task.status == .failed {
                                return "Pipeline failed — email can only be sent after completion"
                            }
                            return "Please wait for the pipeline to complete"
                        }())
                    }
                    
                    Button(action: exportMarkdown) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
                // Bottom Row: Custom Tabs
                HStack(spacing: 24) {
                    ForEach(ResultTab.allCases) { tab in
                        Button {
                            withAnimation(.snappy) {
                                selectedTab = tab
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Text(tab.rawValue)
                                    .font(.system(size: 14))
                                    .fontWeight(selectedTab == tab ? .medium : .regular)
                                    .foregroundColor(selectedTab == tab ? .primary : .secondary)
                                
                                // Active Indicator
                                ZStack {
                                    Rectangle()
                                        .fill(Color.clear)
                                        .frame(height: 2)
                                    if selectedTab == tab {
                                        Rectangle()
                                            .fill(Color.accentColor)
                                            .frame(height: 2)
                                            .matchedGeometryEffect(id: "TabIndicator", in: animationNamespace)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 0)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(Divider(), alignment: .bottom)
            
            // Content
            Group {
                switch selectedTab {
                case .overview:
                    OverviewView(task: task)
                case .transcript:
                    TranscriptView(text: task.derivedTranscriptText() ?? "No transcript available.")
                case .raw:
                    RawDataView(text: task.rawData ?? "No raw data available.")
                case .pipeline:
                    PipelineView(task: task, settings: settings, playback: playback) {
                        withAnimation {
                            selectedTab = .overview
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
    
    private func sendEmail() async {
        isSendingEmail = true
        emailStatus = "Sending..."

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
            emailStatus = "Sent"
        } catch {
            emailStatus = "Failed"
            settings.log("Email failed: \(error.localizedDescription)")
        }

        // Clean up temporary files
        for tempFile in tempFiles {
            try? FileManager.default.removeItem(at: tempFile)
        }

        isSendingEmail = false

        try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
        emailStatus = nil
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(task.safeFilename()).md"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                let content = task.markdownSummary()
                try? content.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

}

struct TaskInfoView: View {
    let task: MeetingTask
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Label("Task Info", systemImage: "info.circle.fill")
                    .font(.headline)
                    .foregroundColor(.accentColor)
                
                Spacer()
                
                // Provider Badge
                if task.inferredProvider != "Unknown" {
                    HStack(spacing: 6) {
                        Image(systemName: task.providerIcon)
                        Text(task.inferredProvider)
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                }
            }
            
            Divider()
            
            // Grid Content
            Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 12) {
                if let key = task.taskKey {
                    GridRow {
                        Text("Task Key")
                            .foregroundColor(.secondary)
                            .gridColumnAlignment(.trailing)
                        
                        HStack {
                            Text(key)
                                .font(.system(.subheadline, design: .monospaced))
                                .textSelection(.enabled)
                            
                            Spacer()
                            
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(key, forType: .string)
                            }) {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Copy Task Key")
                        }
                    }
                }

                if let duration = task.bizDuration {
                    GridRow {
                        Text("Duration")
                            .foregroundColor(.secondary)
                            .gridColumnAlignment(.trailing)
                            
                        Text("\(duration / 1000)s")
                            .font(.subheadline)
                    }
                }
                
                if let mp3 = task.outputMp3Path, let url = URL(string: mp3) {
                    GridRow {
                        Text("Audio")
                            .foregroundColor(.secondary)
                            .gridColumnAlignment(.trailing)
                            
                        Link(destination: url) {
                            Label("Download Audio", systemImage: "arrow.down.circle")
                                .font(.subheadline)
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.1), lineWidth: 1)
        )
    }
}

struct OverviewView: View {
    let task: MeetingTask
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Task Info
                TaskInfoView(task: task)
                
                if let summary = task.summary, !summary.isEmpty {
                    SectionCard(title: "Summary", icon: "doc.text", content: summary, color: .blue)
                }
                
                if let keyPoints = task.keyPoints, !keyPoints.isEmpty {
                    SectionCard(title: "Key Points", icon: "list.bullet", content: keyPoints, color: .orange)
                }
                
                if let actionItems = task.actionItems, !actionItems.isEmpty {
                    SectionCard(title: "Action Items", icon: "checkmark.circle", content: actionItems, color: .green)
                }
                
                if (task.summary == nil && task.keyPoints == nil && task.actionItems == nil) {
                     VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.gray)
                        Text("No analysis results available yet.")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(24)
        }
    }
}

struct TranscriptView: View {
    let text: String
    
    // Split text into paragraphs for lazy loading performance
    private var paragraphs: [String] {
        text.components(separatedBy: "\n")
    }
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.body)
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
        }
    }
}

struct SectionCard: View {
    let title: String
    let icon: String
    let content: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
            }
            
            Text(markdownContent)
                .font(.body)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
    
    private var markdownContent: AttributedString {
        do {
            return try AttributedString(markdown: content)
        } catch {
            return AttributedString(stringLiteral: content)
        }
    }
}

struct RawDataView: View {
    let text: String
    @State private var formattedText: String = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    private let maxTextSize = 50 * 1024 * 1024
    
    var body: some View {
        Group {
            if isLoading {
                VStack {
                    ProgressView()
                    Text("Loading raw data...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    if let error = errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.orange.opacity(0.1))
                    }
                    
                    NativeTextView(text: formattedText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task {
            await formatText()
        }
    }
    
    private func formatText() async {
        isLoading = true
        errorMessage = nil
        
        if text.utf8.count > maxTextSize {
            formattedText = text
            errorMessage = "Raw data is too large to format. Showing original text."
            isLoading = false
            return
        }
        
        let result: (String, String?) = await Task.detached(priority: .userInitiated) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isJson = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
            
            if isJson,
               let data = text.data(using: .utf8),
               let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
               let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
               let prettyString = String(data: prettyData, encoding: .utf8) {
                return (prettyString, nil)
            }
            
            if isJson {
                return (text, "Raw data is not valid JSON. Showing original text.")
            }
            
            return (text, nil)
        }.value
        
        self.formattedText = result.0
        self.errorMessage = result.1
        self.isLoading = false
    }
}

struct NativeTextView: NSViewRepresentable {
    let text: String
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.minSize = NSSize(width: 0, height: 0)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        
        scrollView.documentView = textView
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }
}
