import Foundation
import os

/// 极简统一日志：os.Logger 落系统日志，同时可选回显给界面。
/// 线程安全，Swift 6 下按引用类型手动声明 Sendable（内部只调线程安全的 os.Logger）。
enum Log {
    private static let subsystem = "wang.junjian.minutes"
    private static let general = Logger(subsystem: subsystem, category: "general")
    private static let audio = Logger(subsystem: subsystem, category: "audio")
    private static let engine = Logger(subsystem: subsystem, category: "engine")
    private static let ui = Logger(subsystem: subsystem, category: "ui")

    static func info(_ message: String) { general.info("\(message)") }
    static func warning(_ message: String) { general.warning("\(message)") }
    static func error(_ message: String) { general.error("\(message)") }
    static func audio(_ message: String) { Self.audio.info("\(message)") }
    static func engine(_ message: String) { Self.engine.info("\(message)") }
    static func ui(_ message: String) { Self.ui.debug("\(message)") }
}
