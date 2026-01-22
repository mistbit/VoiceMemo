import SwiftUI

struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    @Binding var selectedTask: MeetingTask?
    @Binding var isRecordingMode: Bool
    
    @State private var searchText = ""
    
    var filteredTasks: [MeetingTask] {
        if searchText.isEmpty {
            return store.tasks
        } else {
            return store.tasks.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var body: some View {
        List(selection: $selectedTask) {
            // New Recording Button Item
            Button(action: {
                selectedTask = nil
                isRecordingMode = true
            }) {
                HStack {
                    if isRecordingMode {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                    } else {
                        Circle()
                            .fill(Color.clear)
                            .frame(width: 8, height: 8)
                    }
                    
                    Label("New Recording", systemImage: "mic.circle.fill")
                        .font(.headline)
                        .foregroundColor(isRecordingMode ? .primary : .secondary)
                    
                    Spacer()
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(isRecordingMode ? Color.gray.opacity(0.1) : Color.clear)
            
            Section(header: Text("History").font(.caption).foregroundColor(.secondary)) {
                ForEach(filteredTasks) { task in
                    NavigationLink(value: task) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(task.title)
                                .font(.system(.body, design: .default))
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            
                            HStack {
                                Text(task.createdAt, style: .date)
                                Text(task.createdAt, style: .time)
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                            
                            StatusBadge(status: task.status)
                        }
                        .padding(.vertical, 6)
                    }
                }
                .onDelete(perform: deleteItems)
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
        .navigationTitle("Meetings")
        .toolbar {
            Button(action: {
                store.refresh()
            }) {
                Image(systemName: "arrow.clockwise")
            }
        }
    }
    
    private func deleteItems(offsets: IndexSet) {
        store.deleteTask(at: offsets)
        if let selected = selectedTask, !store.tasks.contains(where: { $0.id == selected.id }) {
            selectedTask = nil
        }
    }
}

struct StatusBadge: View {
    let status: MeetingTaskStatus
    
    var backgroundColor: Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .recorded: return .blue
        case .transcoding, .uploading, .polling: return .orange
        default: return .gray
        }
    }
    
    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor)
            .foregroundColor(.white)
            .cornerRadius(10)
    }
}
