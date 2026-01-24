import Foundation

protocol StorageProvider {
    func fetchTasks() async throws -> [MeetingTask]
    func saveTask(_ task: MeetingTask) async throws
    func deleteTask(id: UUID) async throws
    func updateTaskTitle(id: UUID, newTitle: String) async throws
    func getTask(id: UUID) async throws -> MeetingTask?
}
