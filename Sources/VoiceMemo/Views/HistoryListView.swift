import SwiftUI
import UniformTypeIdentifiers

struct HistoryListView: View {
    @ObservedObject var store: HistoryStore
    @Binding var selectedTask: MeetingTask?
    
    @State private var searchText = ""
    @State private var pendingDeleteTask: MeetingTask?
    @State private var isShowingDeleteAlert = false
    @State private var taskToRename: MeetingTask?
    @State private var newTitle: String = ""
    @State private var isShowingRenameAlert = false
    
    var filteredTasks: [MeetingTask] {
        let currentTasks = store.tasks // 创建快照避免并发问题
        if searchText.isEmpty {
            return currentTasks
        } else {
            return currentTasks.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var body: some View {
        Group {
            if store.isLoading && filteredTasks.isEmpty {
                ProgressView("Loading history...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.error {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    
                    Text("Failed to load history")
                        .font(.headline)
                    
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button("Retry") {
                        Task { await store.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredTasks.isEmpty {
                EmptyStateView(searchText: searchText)
            } else {
                List(selection: $selectedTask) {
                    ForEach(filteredTasks) { task in
                        NavigationLink(value: task) {
                            HistoryRow(task: task)
                        }
                        .contextMenu {
                            Button {
                                taskToRename = task
                                newTitle = task.title
                                isShowingRenameAlert = true
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }

                            Divider()

                            Button(role: .destructive) {
                                pendingDeleteTask = task
                                isShowingDeleteAlert = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete(perform: deleteItems)
                }
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
        .alert("Delete Meeting?", isPresented: $isShowingDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let task = pendingDeleteTask {
                    store.deleteTask(task)
                    if selectedTask?.id == task.id {
                        selectedTask = nil
                    }
                }
                pendingDeleteTask = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteTask = nil
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .alert("Rename Meeting", isPresented: $isShowingRenameAlert) {
            TextField("New Title", text: $newTitle)
            Button("Save") {
                if let task = taskToRename, !newTitle.isEmpty {
                    store.updateTitle(for: task, newTitle: newTitle)
                }
                taskToRename = nil
            }
            Button("Cancel", role: .cancel) {
                taskToRename = nil
            }
        }
    }
    
    private func deleteItems(offsets: IndexSet) {
        let tasksToDelete = offsets.compactMap { index in
            filteredTasks.indices.contains(index) ? filteredTasks[index] : nil
        }
        store.deleteTasks(tasksToDelete)
        if let selected = selectedTask, !store.tasks.contains(where: { $0.id == selected.id }) {
            selectedTask = nil
        }
    }
}

struct EmptyStateView: View {
    let searchText: String
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: searchText.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text(searchText.isEmpty ? "No History" : "No Results")
                .font(.headline)
                .foregroundColor(.primary)
            
            Text(searchText.isEmpty ? "Your meeting recordings will appear here" : "No recordings match '\(searchText)'")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HistoryRow: View {
    let task: MeetingTask
    
    private var formattedDuration: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: task.createdAt, relativeTo: Date())
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundColor(.primary)
                
                Spacer()
                
                if task.status == .completed {
                    Text(formattedDuration)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            HStack {
                Text(formattedDuration)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .opacity(task.status == .completed ? 0 : 1) // 已完成时隐藏，因为上面已显示
                
                Spacer()
                
                StatusBadge(status: task.status)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

struct StatusBadge: View {
    let status: MeetingTaskStatus
    
    private var color: Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .recorded: return .blue
        case .transcoding, .uploading, .polling: return .orange
        default: return .gray
        }
    }
    
    private var isProcessing: Bool {
        switch status {
        case .transcoding, .uploading, .uploadingRaw, .polling:
            return true
        default:
            return false
        }
    }
    
    var body: some View {
        HStack(spacing: 6) {
            if isProcessing {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            
            Text(status.displayName)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.2), lineWidth: 0.5)
        )
    }
}
