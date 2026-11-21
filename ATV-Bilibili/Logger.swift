//
//  Logger.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2022/12/9.
//

import CocoaLumberjackSwift
import Foundation

class Logger {
    private static let fileLogger = DDFileLogger()
    static func setup() {
        #if DEBUG
            // Debug 保持全量，真机 /debug/log 排障不受影响
            DDLog.add(DDOSLogger.sharedInstance)
            DDLog.add(fileLogger)
        #else
            // Release：os_log 只收 warning+、文件保留 info（诊断可回溯），dynamicLogLevel
            // 在源头拦掉 debug（连字符串插值都不发生）；此前默认 .all 全量落盘
            DDLog.add(DDOSLogger.sharedInstance, with: .warning)
            DDLog.add(fileLogger, with: .info)
            dynamicLogLevel = .info
        #endif
        fileLogger.logFormatter = DDLogFileFormatterDefault(dateFormatter: DateFormatter.logFileTimestamp)
        fileLogger.rollingFrequency = 60 * 60 * 24 // 24 hours
        fileLogger.logFileManager.maximumNumberOfLogFiles = 2
        fileLogger.doNotReuseLogFiles = true
        fileLogger.maximumFileSize = 1024 * 1024 * 5
    }

    static func debug(_ message: @autoclosure () -> DDLogMessageFormat,
                      file: StaticString = #file,
                      function: StaticString = #function,
                      line: UInt = #line)
    {
        #if DEBUG
            DDLogDebug(message(), file: file, function: function, line: line)
        #endif
    }

    static func info(_ message: @autoclosure () -> DDLogMessageFormat,
                     file: StaticString = #file,
                     function: StaticString = #function,
                     line: UInt = #line)
    {
        DDLogInfo(message(), file: file, function: function, line: line)
    }

    static func warn(_ message: @autoclosure () -> DDLogMessageFormat,
                     file: StaticString = #file,
                     function: StaticString = #function,
                     line: UInt = #line)
    {
        DDLogWarn(message(), file: file, function: function, line: line)
    }

    static func warn(_ error: Any,
                     file: StaticString = #file,
                     function: StaticString = #function,
                     line: UInt = #line)
    {
        DDLogWarn("\(error)", file: file, function: function, line: line)
    }

    static func latestLogPath() -> String? {
        fileLogger.logFileManager.sortedLogFilePaths.first
    }
}
