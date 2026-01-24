import Foundation
import Combine

class HistoryStore: ObservableObject {
    @Published var tasks: [MeetingTask] = []
    
    init() {
        Task { await refresh() }
    }
    
    @MainActor
    func refresh() async {
        do {
            tasks = try await StorageManager.shared.currentProvider.fetchTasks()
        } catch {
            print("HistoryStore refresh error: \(error)")
        }
    }
    
    func deleteTask(at offsets: IndexSet) {
        let tasksToDelete = offsets.map { tasks[$0] }
        Task {
            for task in tasksToDelete {
                try? await StorageManager.shared.currentProvider.deleteTask(id: task.id)
            }
            await refresh()
        }
    }

    func deleteTask(_ task: MeetingTask) {
        Task {
            try? await StorageManager.shared.currentProvider.deleteTask(id: task.id)
            await refresh()
        }
    }

    func deleteTasks(_ tasks: [MeetingTask]) {
        Task {
            for task in tasks {
                try? await StorageManager.shared.currentProvider.deleteTask(id: task.id)
            }
            await refresh()
        }
    }

    func updateTitle(for task: MeetingTask, newTitle: String) {
        Task {
            try? await StorageManager.shared.currentProvider.updateTaskTitle(id: task.id, newTitle: newTitle)
            await refresh()
        }
    }
}
