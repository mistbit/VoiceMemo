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
        if searchText.isEmpty {
            return store.tasks
        } else {
            return store.tasks.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var body: some View {
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

struct HistoryRow: View {
    let task: MeetingTask
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundColor(.primary)
                Spacer()
                if task.status == .completed {
                    Text(task.createdAt, style: .date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            HStack {
                if task.status != .completed {
                     Text(task.createdAt, style: .date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                StatusBadge(status: task.status)
                if task.status == .completed {
                    Spacer()
                }
            }
        }
        .padding(.vertical, 6)
    }
}

struct StatusBadge: View {
    let status: MeetingTaskStatus
    
    var color: Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .recorded: return .blue
        case .transcoding, .uploading, .polling: return .orange
        default: return .gray
        }
    }
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            
            Text(status.rawValue.capitalized)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(.primary.opacity(0.8))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.1))
        .cornerRadius(4)
    }
}
