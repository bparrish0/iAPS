//
//  OSLog.swift
//  Loop
//
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import Foundation
import ObjectiveC
import os.log

private var osLogCategoryKey: UInt8 = 0

extension OSLog {
    convenience init(category: String) {
        self.init(subsystem: "com.ps2.rileylink", category: category)
        objc_setAssociatedObject(self, &osLogCategoryKey, category, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private var storedCategory: String {
        (objc_getAssociatedObject(self, &osLogCategoryKey) as? String) ?? "unknown"
    }

    func debug(_ message: StaticString, _ args: CVarArg...) {
        log(message, type: .debug, args)
    }

    func info(_ message: StaticString, _ args: CVarArg...) {
        log(message, type: .info, args)
    }

    func `default`(_ message: StaticString, _ args: CVarArg...) {
        log(message, type: .default, args)
    }

    func error(_ message: StaticString, _ args: CVarArg...) {
        log(message, type: .error, args)
    }

    private func log(_ message: StaticString, type: OSLogType, _ args: [CVarArg]) {
        switch args.count {
        case 0:
            os_log(message, log: self, type: type)
        case 1:
            os_log(message, log: self, type: type, args[0])
        case 2:
            os_log(message, log: self, type: type, args[0], args[1])
        case 3:
            os_log(message, log: self, type: type, args[0], args[1], args[2])
        case 4:
            os_log(message, log: self, type: type, args[0], args[1], args[2], args[3])
        case 5:
            os_log(message, log: self, type: type, args[0], args[1], args[2], args[3], args[4])
        default:
            os_log(message, log: self, type: type, args)
        }

        let level: RileyLinkLogLevel
        switch type {
        case .debug: level = .debug
        case .info: level = .info
        case .error, .fault: level = .error
        default: level = .default
        }

        let format = "\(message)"
            .replacingOccurrences(of: "%{public}", with: "%")
            .replacingOccurrences(of: "%{private}", with: "%")
        let formatted = String(format: format, arguments: args)

        let entry = RileyLinkLogEntry(
            timestamp: Date(),
            category: storedCategory,
            level: level,
            message: formatted
        )
        RileyLinkLogBuffer.shared.append(entry)
    }
}
