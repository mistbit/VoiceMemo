import Foundation
import Combine

class HistoryStore: ObservableObject {
    @Published var tasks: [MeetingTask] = []
    
    init() {
        refresh()
    }
    
    func refresh() {
        tasks = DatabaseManager.shared.fetchTasks()
    }
    
    func deleteTask(at offsets: IndexSet) {
        for index in offsets {
            let task = tasks[index]
            DatabaseManager.shared.deleteTask(id: task.id)
        }
        refresh()
    }

    func deleteTask(_ task: MeetingTask) {
        DatabaseManager.shared.deleteTask(id: task.id)
        refresh()
    }

    func deleteTasks(_ tasks: [MeetingTask]) {
        for task in tasks {
            DatabaseManager.shared.deleteTask(id: task.id)
        }
        refresh()
    }

    func updateTitle(for task: MeetingTask, newTitle: String) {
        DatabaseManager.shared.updateTaskTitle(id: task.id, newTitle: newTitle)
        refresh()
    }
}
