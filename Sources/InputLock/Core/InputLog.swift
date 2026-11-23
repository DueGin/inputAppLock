import Foundation

@MainActor
enum InputLog {
    private static let maximumSize = 512 * 1024
    private static let fileManager = FileManager.default
    private static let directory = fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/InputLock", isDirectory: true)
    private static let file = directory.appendingPathComponent("input.log")
    private static let formatter = ISO8601DateFormatter()

    static func write(_ message: String) {
        let line = message.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard let data = "\(formatter.string(from: Date())) \(line)\n".data(using: .utf8),
              data.count <= maximumSize else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let attributes = try? fileManager.attributesOfItem(atPath: file.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            if size + data.count > maximumSize {
                let previous = directory.appendingPathComponent("input.log.1")
                if fileManager.fileExists(atPath: previous.path) {
                    try fileManager.removeItem(at: previous)
                }
                try fileManager.moveItem(at: file, to: previous)
            }
            if !fileManager.fileExists(atPath: file.path) {
                guard fileManager.createFile(atPath: file.path, contents: nil) else { return }
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }
}
