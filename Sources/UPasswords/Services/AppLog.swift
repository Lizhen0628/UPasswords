import Foundation

/// 统一日志设施:写 `~/Library/Application Support/UPasswords/Logs/UPasswords.log`,
/// 并镜像到 stderr(终端直接跑二进制时可见)。
///
/// 排查定位指南:
/// - 级别门控:DEBUG 构建默认 `debug`,release 默认 `info`。现场排查可用
///   `UP_LOG_LEVEL=debug` 环境变量,或 `defaults write com.upasswords.UPasswords log.level -string debug`
///   提升详细程度(无需重新编译);启动横幅会打印当前生效级别。
/// - 每次启动打印横幅(版本/macOS/构建配置/pid/日志路径),按横幅分段即可
///   把日志按「次启动」切开。
/// - 写盘在串行队列异步执行,调用方(含主线程)不被磁盘 I/O 阻塞;
///   error 级同步落盘,崩溃前不丢关键行;退出前经 `flush()` 冲刷。
///
/// 隐私红线:绝不记录密码、卡片字段值、笔记内容等敏感数据——只记录
/// 操作、对象名/ID、字节长度、错误与耗时。排查问题不需要明文。
///
/// 用法:`Log.info("db", "created \"main.upw\" (7.3KB, 12ms)")`
/// 输出:`2026-09-22 21:47:03.123 [info][db] created "main.upw" (7.3KB, 12ms)`
enum Log {
    enum Level: String, CaseIterable, Comparable {
        case debug, info, warn, error
        private var rank: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warn: return 2
            case .error: return 3
            }
        }
        static func < (l: Level, r: Level) -> Bool { l.rank < r.rank }
    }

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("UPasswords/Logs", isDirectory: true)
    }
    static var fileURL: URL { dir.appendingPathComponent("UPasswords.log") }

    /// 超过该大小轮转为 .old.log(保留一代),避免无限膨胀。
    private static let rotateBytes = 1_000_000

    /// 生效的最低输出级别:env `UP_LOG_LEVEL` > UserDefaults `log.level` > 构建默认。
    static let minLevel: Level = {
        let raw = ProcessInfo.processInfo.environment["UP_LOG_LEVEL"]
            ?? UserDefaults.standard.string(forKey: "log.level")
        if let raw, let level = Level(rawValue: raw.lowercased()) { return level }
        #if DEBUG
        return .debug
        #else
        return .info
        #endif
    }()

    private static let queue = DispatchQueue(label: "upasswords.applog")
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var writtenBytes = 0
    nonisolated(unsafe) private static var bootLogged = false

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // @autoclosure:被级别门控挡掉的日志不做字符串插值,零开销。
    static func debug(_ category: String, _ message: @autoclosure () -> String) {
        guard minLevel <= .debug else { return }
        write(.debug, category, message())
    }
    static func info(_ category: String, _ message: @autoclosure () -> String) {
        guard minLevel <= .info else { return }
        write(.info, category, message())
    }
    static func warn(_ category: String, _ message: @autoclosure () -> String) {
        guard minLevel <= .warn else { return }
        write(.warn, category, message())
    }
    static func error(_ category: String, _ message: @autoclosure () -> String) {
        guard minLevel <= .error else { return }
        write(.error, category, message())
    }

    /// 每次启动的分隔横幅:版本、系统、构建配置、日志级别、关键环境变量,
    /// 方便把日志按次启动分段并确认排查时的运行环境。
    static func bootstrap() {
        queue.sync {
            guard !bootLogged else { return }
            bootLogged = true
            var config = "RELEASE"
            #if DEBUG
            config = "DEBUG"
            #endif
            var env = ""
            for key in ["UP_SCREENSHOT_BOOT", "UP_SCREENSHOT_SIZE", "UP_LOG_LEVEL"] {
                if let v = ProcessInfo.processInfo.environment[key] { env += " \(key)=\(v)" }
            }
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let line = "launch ver=\(version)(\(build)) macOS=\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) "
                + "locale=\(Locale.current.identifier) pid=\(ProcessInfo.processInfo.processIdentifier) "
                + "config=\(config) minLevel=\(minLevel.rawValue)\(env) log=\(fileURL.path)"
            emit(.info, "app", "────── \(line)")
        }
    }

    /// 冲刷异步写盘队列(退出/崩溃上报前调用)。
    static func flush() { queue.sync {} }

    private static func write(_ level: Level, _ category: String, _ message: String) {
        if level == .error {
            queue.sync { emit(level, category, message) }   // 错误同步落盘
        } else {
            queue.async { emit(level, category, message) }
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
