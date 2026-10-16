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
        DDLog.add(DDOSLogger.sharedInstance)
        fileLogger.logFormatter = DDLogFileFormatterDefault(dateFormatter: DateFormatter.logFileTimestamp)
        fileLogger.rollingFrequency = 60 * 60 * 24 // 24 hours
        fileLogger.logFileManager.maximumNumberOfLogFiles = 2
        fileLogger.doNotReuseLogFiles = true
        fileLogger.maximumFileSize = 1024 * 1024 * 5
        DDLog.add(fileLogger)
    }

    static func debug(_ message: @autoclosure () -> DDLogMessageFormat,
                      file: StaticString = #file,
                      function: StaticString = #function,
                      line: UInt = #line)
    {
        DDLogDebug(message(), file: file, function: function, line: line)
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
