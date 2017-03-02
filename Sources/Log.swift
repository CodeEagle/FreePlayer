//
//  Log.swift
//  FreePlayer
//
//  Created by Lincoln Law on 2017/2/22.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//

import Foundation
/// FreePlayer 🖨️模块
public struct FPLogger {
    public static var shared = FPLogger()
    /// 当前的记录文件
    public private(set) var logfile: String
    /// 是否记录到文件，默认开启
    public var logToFile: Bool = false { didSet { toggleEnableLog() } }
    /// 记录文件的目录
    public private(set) var logFolder: String
    private var _modules = Set<Module>()
    private var _date = ""
    private var _writeStream: CFWriteStream?
    private var _logQueue = DispatchQueue(label: "com.SelfStudio.Freeplayer.logger")
    private var _openTime = ""
    
    private init() {
        if let ver = Bundle(for: AudioStream.self).infoDictionary?["CFBundleShortVersionString"] as? String, let version = Double(ver) {
            FreePlayerVersion = version
        }
        let cache = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first!
        let dir = (cache as NSString).appendingPathComponent("FreePlayer")
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: false, attributes: nil)
        }
        logFolder = dir
        let date = Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.locale = Locale.current
        let total = fmt.string(from: date).components(separatedBy: " ")
        _date = total.first ?? ""
        _openTime = total.last ?? ""
        logfile = dir + "/\(_date).log"
    }
    /// 开启打印
    ///
    /// 默认全部开启
    /// - Parameter modules: 需要开启的模块
    public static func enable(modules: Set<Module> = Module.All) {
        for item in modules { shared._modules.insert(item) }
    }
    /// 关闭打印
    ///
    /// 默认全部关闭
    /// - Parameter modules: 需要关闭的模块
    public static func disable(modules: Set<Module> = Module.All) {
        for item in modules { shared._modules.remove(item) }
    }
    /// 清理记录文件
    public static func cleanAllLog() {
        let fm = FileManager.default
        let dir = shared.logFolder
        try? fm.removeItem(atPath: dir)
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: false, attributes: nil)
        }
    }
    
    public enum Module {
        case audioQueue, audioStream, cachingStream, fileStream, httpStream, freePlayer
        var symbolize: String {
            switch self {
            case .audioQueue: return "🌈"
            case .audioStream: return "☀️"
            case .httpStream: return "🌨"
            case .fileStream: return "🌤"
            case .cachingStream: return "❄️"
            case .freePlayer: return "☄️"
            }
        }
        static var All: Set<Module> { return [.audioQueue, .audioStream, .httpStream, .fileStream, .cachingStream] }
        
        func log(msg: Any, method: String = #function) {
            if shared._modules.isEmpty || shared._modules.contains(self) == false { return }
            let total = "\(symbolize)\(method):\(msg)"
            print(total)
            FPLogger.write(msg: total)
        }
        
        func condition(_ condition: Bool, message: String = "", method: String = #function) {
            if shared._modules.isEmpty || shared._modules.contains(self) == false { return }
            if condition == false { FPLogger.write(msg: method + ":" + message) }
            assert(condition, message)
        }
    }
    
    private mutating func toggleEnableLog() {
        if logToFile {
            let url = URL(fileURLWithPath: logfile)
            let old = (try? String(contentsOf: url)) ?? ""
            guard let stream = CFWriteStreamCreateWithFile(kCFAllocatorDefault, url as CFURL) else { return }
            CFWriteStreamOpen(stream)
            _writeStream = stream
            let msg = old + "\n-----------------Freeplayer[\(FreePlayerVersion)]@\(_openTime)-----------------\n"
            guard let data = msg.data(using: .utf8) else { return }
            var pointer = data.map{ $0 }
            CFWriteStreamWrite(stream, &pointer, data.count)
        } else {
            guard let stream = _writeStream else { return }
            CFWriteStreamClose(stream)
        }
    }
    
    private static func write(msg: String) {
        guard let stream = shared._writeStream, let data = msg.data(using: .utf8) else { return }
        var pointer = data.map{$0}
        shared._logQueue.async {
            CFWriteStreamWrite(stream, &pointer, data.count)
        }
    }
}

func as_log(_ msg: Any, function: String = #function) {
    FPLogger.Module.audioStream.log(msg: msg, method: function)
}

func cs_log(_ msg: Any, function: String = #function) {
    FPLogger.Module.cachingStream.log(msg: msg, method: function)
}

func hs_log(_ msg: Any, function: String = #function) {
    FPLogger.Module.httpStream.log(msg: msg, method: function)
}

func aq_log(_ msg: Any..., method: String = #function) {
    FPLogger.Module.audioQueue.log(msg: msg, method: method)
}

func aq_assert(_ condition: Bool, message: String = "", method: String = #function) {
    FPLogger.Module.audioQueue.condition(condition, message: message, method: method)
}

func fp_log(_ msg: Any..., method: String = #function) {
    FPLogger.Module.freePlayer.log(msg: msg, method: method)
}

func debug_log(_ msg: Any...) {
    #if DEBUG || ((arch(i386) || arch(x86_64)) && os(iOS))
        print(msg)
    #endif
}
