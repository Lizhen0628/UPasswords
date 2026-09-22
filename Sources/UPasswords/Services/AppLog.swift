import Foundation

/// 开发阶段统一日志设施:全级别、全构建(含 dist release)写
/// `~/Library/Application Support/UPasswords/Logs/UPasswords.log`,
/// 并镜像到 stderr(终端直接跑二进制时可见)。
///
/// 隐私红线:绝不记录密码、卡片字段值、笔记内容等敏感数据——只记录
/// 操作、对象名/ID、字节长度、错误与耗时。排查问题不需要明文。
///
/// 用法:`Log.info("db", "created \"main.upw\" (7.3KB, 12ms)")`
/// 输出:`2026-09-22 21:47:03.123 [info][db] created "main.upw" (7.3KB, 12ms)`
enum Log {
    enum Level: String {
        case debug, info, warn, error
    }

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("UPasswords/Logs", isDirectory: true)
    }
    static var fileURL: URL { dir.appendingPathComponent("UPasswords.log") }

    /// 超过该大小轮转为 .old.log(保留一代),避免开发期无限膨胀。
    private static let rotateBytes = 1_000_000

    nonisolated(unsafe) private static let queue = DispatchQueue(label: "upasswords.applog")
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var writtenBytes = 0
    nonisolated(unsafe) private static var bootLogged = false

    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func debug(_ category: String, _ message: String) { write(.debug, category, message) }
    static func info(_ category: String, _ message: String) { write(.info, category, message) }
    static func warn(_ category: String, _ message: String) { write(.warn, category, message) }
    static func error(_ category: String, _ message: String) { write(.error, category, message) }

    /// 每次启动的分隔横幅:版本、构建配置、关键环境变量,方便把日志按次启动分段。
    static func bootstrap() {
        var config = "RELEASE"
        #if DEBUG
        config = "DEBUG"
        #endif
        var env = ""
        for key in ["UP_SCREENSHOT_BOOT", "UP_SCREENSHOT_SIZE"] {
            if let v = ProcessInfo.processInfo.environment[key] { env += " \(key)=\(v)" }
        }
        let line = "launch pid=\(ProcessInfo.processInfo.processIdentifier) "
            + "config=\(config)\(env) log=\(fileURL.path)"
        queue.sync {
            guard !bootLogged else { return }
            bootLogged = true
            emit(.info, "app", "────── \(line)")
        }
    }

    private static func write(_ level: Level, _ category: String, _ message: String) {
        queue.sync {
            emit(level, category, message)
        }
    }

    /// 只能在 queue 上调用(否则 formatter/handle 竞争)。
    private static func emit(_ level: Level, _ category: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level.rawValue)][\(category)] \(message)\n"
        let data = Data(line.utf8)
        FileHandle.standardError.write(data)   // 终端可见(stderr);Finder 启动时无处输出,无副作用
        ensureOpen()
        handle?.write(data)
        writtenBytes += data.count
        if writtenBytes > rotateBytes { rotate() }
    }

    private static func ensureOpen() {
        guard handle == nil else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
        writtenBytes = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    private static func rotate() {
        handle?.closeFile()
        handle = nil
        let old = dir.appendingPathComponent("UPasswords.old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: fileURL, to: old)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
        writtenBytes = 0
        emit(.info, "app", "rotated previous log")
    }
}
