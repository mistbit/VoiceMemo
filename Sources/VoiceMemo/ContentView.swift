import SwiftUI
import ScreenCaptureKit

struct ContentView: View {
    @ObservedObject var settings: SettingsStore
    @StateObject private var recorder: AudioRecorder
    @StateObject private var historyStore = HistoryStore()
    @StateObject private var playback = AudioPlaybackController()
    
    // Navigation State
    @State private var selectedSidebarItem: SidebarItem? = .history
    @State private var selectedRecordingMode: RecordingModeItem? = .mixed
    @State private var selectedImportMode: ImportModeItem?
    @State private var selectedSettingsCategory: SettingsCategory? = .general
    @State private var selectedTask: MeetingTask?
    
    // Import State
    @State private var isImporting = false
    @State private var importError: String?
    
    init(settings: SettingsStore) {
        self.settings = settings
        _recorder = StateObject(wrappedValue: AudioRecorder(settings: settings))
        _selectedRecordingMode = State(initialValue: RecordingModeItem(rawValue: settings.recordingMode.rawValue) ?? .mixed)
    }
    
    // Method to navigate to a task in history
    func navigateToTask(_ task: MeetingTask) {
        selectedSidebarItem = .history
        selectedTask = task
    }
    
    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selectedSidebarItem) { item in
                NavigationLink(value: item) {
                    Label(item.title, systemImage: item.icon)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Voice Memo")
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)
        } content: {
            ZStack {
                if let item = selectedSidebarItem {
                    switch item {
                    case .recording:
                        List(RecordingModeItem.allCases, selection: $selectedRecordingMode) { mode in
                            NavigationLink(value: mode) {
                                VStack(alignment: .leading) {
                                    Label(mode.title, systemImage: mode.icon)
                                    Text(mode.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .navigationTitle("Recording")
                        
                    case .importAudio:
                        List(ImportModeItem.allCases, selection: $selectedImportMode) { mode in
                            NavigationLink(value: mode) {
                                VStack(alignment: .leading) {
                                    Label(mode.title, systemImage: mode.icon)
                                    Text(mode.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .navigationTitle("Import")
                        
                    case .history:
                        HistoryListView(store: historyStore, playback: playback, selectedTask: $selectedTask)
                            .navigationTitle("History")
                        
                    case .settings:
                        List(SettingsCategory.allCases, selection: $selectedSettingsCategory) { category in
                            NavigationLink(value: category) {
                                VStack(alignment: .leading) {
                                    Label(category.title, systemImage: category.icon)
                                    Text(category.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .navigationTitle("Settings")
                    }
                } else {
                    Text("Select an item")
                        .foregroundColor(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 400)
        } detail: {
            if let item = selectedSidebarItem {
                switch item {
                case .recording:
                    RecordingView(recorder: recorder, settings: settings, playback: playback, onViewResult: {
                        if let task = recorder.latestTask {
                            navigateToTask(task)
                        }
                    })
                    
                case .importAudio:
                    if let mode = selectedImportMode {
                        switch mode {
                        case .file:
                            if isImporting {
                                VStack(spacing: 16) {
                                    ProgressView()
                                        .scaleEffect(1.5)
                                    Text("Importing...")
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                ImportView { files in
                                    handleImport(files: files)
                                }
                            }
                        }
                    } else {
                        Text("Select an import method")
                            .foregroundColor(.secondary)
                    }
                    
                case .history:
                    if let task = selectedTask {
                        ResultView(task: task, settings: settings, playback: playback)
                            .id(task.id)
                    } else {
                        Text("Select a meeting to view details")
                            .foregroundColor(.secondary)
                    }
                    
                case .settings:
                    if let category = selectedSettingsCategory {
                        SettingsView(settings: settings, category: category)
                    } else {
                        Text("Select a settings category")
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Text("Welcome to Voice Memo")
                    .foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 1000, minHeight: 600)
        .onChange(of: recorder.latestTask?.id) { _ in
            Task { await historyStore.refresh() }
        }
        .onChange(of: selectedRecordingMode) { newValue in
            if let newValue {
                settings.recordingMode = SettingsStore.RecordingMode(rawValue: newValue.rawValue) ?? .mixed
            }
        }
        .onChange(of: settings.recordingMode) { newValue in
            selectedRecordingMode = RecordingModeItem(rawValue: newValue.rawValue) ?? .mixed
        }
        .alert("Import Failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { }
        } message: {
            if let error = importError {
                Text(error)
            }
        }
    }
    
    private func handleImport(files: [URL]) {
        isImporting = true
        importError = nil
        
        Task {
            do {
                let newTask = try await historyStore.importTask(files: files)
                await MainActor.run {
                    isImporting = false
                    selectedSidebarItem = .history
                    selectedTask = newTask
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    importError = error.localizedDescription
                }
            }
        }
    }
}
