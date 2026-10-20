//
//  PCLogger.swift
//  PCVapPlayer
//
//  Created by converting from Objective-C
//  Copyright © 2024. All rights reserved.
//

import Foundation

let kPCVAPModuleCommon = "kPCVAPModuleCommon"

/// 日志级别
public enum LogLevel: Int {
    case all = 0
    case debug      // 详细的流程信息
    case info       // 运行时事件（启动/关闭），应该保守并保持最少
    case event
    case warn       // 其他不期望的运行时情况，但不一定是"错误"
    case error      // 其他运行时错误或意外条件
    case fatal      // 导致提前终止的严重错误
    case none       // 用于禁用所有日志消息的特殊级别
}

public typealias HWDLogLevel = LogLevel

/// 日志函数类型
public typealias PCLoggerFunc = (LogLevel, String, Int, String, String, String) -> Void

var externalPCLogger: PCLoggerFunc?

/// 内部日志处理器
func internalPCLoggerHandler(level: LogLevel, file: String, line: Int, function: String, module: String, format: String, _ arguments: CVarArg...) {
    #if DEBUG
//    let message = String(format: format, arguments: arguments)
//    let fileName = (file as NSString).lastPathComponent
    // 可以在这里添加日志输出
    #endif
}

/// 日志宏
func VAPPCLogger(_ level: LogLevel, _ module: String, _ format: String, _ arguments: CVarArg...) {
//    let file = #file
//    let line = #line
//    let function = #function
    
//    if let externalPCLogger = externalPCLogger {
//        let message = String(format: format, arguments: arguments)
//        externalPCLogger(level, file, line, function, module, message)
//    } else {
//        internalPCLoggerHandler(level: level, file: file, line: line, function: function, module: module, format: format, arguments)
//    }
}

func PCVAPError(_ module: String, _ format: String, _ arguments: CVarArg...) {
    VAPPCLogger(.error, module, format, arguments)
}

func PCVAPEvent(_ module: String, _ format: String, _ arguments: CVarArg...) {
    VAPPCLogger(.event, module, format, arguments)
}

func VAPWarn(_ module: String, _ format: String, _ arguments: CVarArg...) {
    VAPPCLogger(.warn, module, format, arguments)
}

func PCVAPInfo(_ module: String, _ format: String, _ arguments: CVarArg...) {
    VAPPCLogger(.info, module, format, arguments)
}

func VAPDebug(_ module: String, _ format: String, _ arguments: CVarArg...) {
    VAPPCLogger(.debug, module, format, arguments)
}

/// 日志管理器
public class PCLogger {
    /// 注册外部日志函数
    public static func registerExternalLog(_ logger: @escaping PCLoggerFunc) {
        externalPCLogger = logger
    }
    
    /// 记录日志
    static func log(level: LogLevel, file: String, line: Int, function: String, module: String, message: String) {
        var safeMessage = message
        if message.contains("%") {
            // 此处是为了兼容 % 进入 format 之后的 crash 风险
            safeMessage = message.replacingOccurrences(of: "%", with: "")
        }
        
        if let externalPCLogger = externalPCLogger {
            externalPCLogger(level, file, line, function, module, safeMessage)
        } else {
            internalPCLoggerHandler(level: level, file: file, line: line, function: function, module: module, format: safeMessage)
        }
    }
}

