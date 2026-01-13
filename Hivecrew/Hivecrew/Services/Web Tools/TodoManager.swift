//
//  TodoManager.swift
//  Hivecrew
//
//  Todo list management for agent task planning
//

import Foundation

/// Manages a single todo list for an agent session
public class TodoManager: Sendable {
    
    private let lock = NSLock()
    private var list: TodoList?
    
    public init() {}
    
    /// Create the todo list (only one per agent)
    /// - Parameters:
    ///   - title: The title of the todo list
    ///   - items: Optional initial items to add
    /// - Returns: The created todo list
    public func createList(title: String, items: [String]? = nil) -> TodoList {
        lock.lock()
        defer { lock.unlock() }
        
        let newList = TodoList(title: title)
        
        // Add initial items if provided
        if let items = items {
            for itemText in items {
                let item = TodoItem(text: itemText)
                newList.items.append(item)
            }
        }
        
        self.list = newList
        return newList
    }
    
    /// Add an item to the todo list
    /// - Parameter itemText: The text of the item to add
    /// - Returns: The index of the newly added item (1-based)
    public func addItem(itemText: String) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        
        guard let list = list else {
            throw TodoManagerError.noListCreated
        }
        
        let item = TodoItem(text: itemText)
        list.items.append(item)
        return list.items.count // Return 1-based index
    }
    
    /// Mark a todo item as finished by index
    /// - Parameter index: The 1-based index of the item to finish
    public func finishItem(index: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        
        guard let list = list else {
            throw TodoManagerError.noListCreated
        }
        
        // Convert 1-based to 0-based index
        let arrayIndex = index - 1
        
        guard arrayIndex >= 0 && arrayIndex < list.items.count else {
            throw TodoManagerError.invalidIndex(index, count: list.items.count)
        }
        
        let item = list.items[arrayIndex]
        item.isCompleted = true
        item.completedAt = Date()
    }
    
    /// Get the todo list for serialization
    public func getList() -> TodoList? {
        lock.lock()
        defer { lock.unlock() }
        return list
    }
    
    /// Serialize the todo list to JSON for session trace
    public func toJSON() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        
        guard let list = list else {
            return try JSONEncoder().encode([TodoList]())
        }
        
        return try JSONEncoder().encode([list])
    }
    
    enum TodoManagerError: LocalizedError {
        case noListCreated
        case invalidIndex(Int, count: Int)
        
        var errorDescription: String? {
            switch self {
            case .noListCreated:
                return "No todo list has been created yet. Use create_todo_list first."
            case .invalidIndex(let index, let count):
                return "Invalid item index \(index). Todo list has \(count) items (use 1-\(count))."
            }
        }
    }
}

/// A todo list with items
public class TodoList: Codable, Sendable {
    public let id: String
    public let title: String
    public let createdAt: Date
    public var items: [TodoItem]
    
    init(title: String) {
        self.id = UUID().uuidString
        self.title = title
        self.createdAt = Date()
        self.items = []
    }
}

/// A single todo item
public class TodoItem: Codable, Sendable {
    public let id: String
    public let text: String
    public let createdAt: Date
    public var isCompleted: Bool
    public var completedAt: Date?
    
    init(text: String) {
        self.id = UUID().uuidString
        self.text = text
        self.createdAt = Date()
        self.isCompleted = false
        self.completedAt = nil
    }
}
