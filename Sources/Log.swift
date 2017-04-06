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
    
    typealias MessageHandler = (String) -> Void
    public static var shared = FPLogger()
    /// 当前的记录文件
    public private(set) var logfile: String
    /// 是否记录到文件，默认开启
    public var logToFile: Bool = false { didSet { toggleEnableLog() } }
    /// 记录文件的目录
    public private(set) var logFolder: String
    private var _modules = Set<Module>()
    private var _date = ""
    private var _fileHandler: FileHandle?
    private var _logQueue = DispatchQueue(label: "com.SelfStudio.Freeplayer.logger")
    private var _openTime = ""
    var lastRead = UInt64()
    var totalSize = UInt64()
    
    static let lineSeperator = "\n\n\n"
    
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
        logToFile = UserDefaults.standard.bool(forKey: "FreePlayer.LogToFile")
        toggleEnableLog()
        DispatchQueue.global(qos: .userInitiated).setTarget(queue: _logQueue)
        NotificationCenter.default.addObserver(forName: NSNotification.Name.UIApplicationWillTerminate, object: nil, queue: OperationQueue.main) { (_) in
            // 崩溃前保存记录
            FPLogger.shared.logToFile = false
        }
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
        let needStopLogging = FPLogger.shared.logToFile
        if needStopLogging {
            FPLogger.shared.logToFile = false
        }
        let fm = FileManager.default
        let dir = shared.logFolder
        try? fm.removeItem(atPath: dir)
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: false, attributes: nil)
        }
        if needStopLogging {  FPLogger.shared.logToFile = true }
    }
    
    public enum Module {
        case audioQueue, audioStream, cachingStream, fileStream, httpStream, freePlayer, id3Parser
        var symbolize: String {
            switch self {
            case .audioQueue: return "🌈"
            case .audioStream: return "☀️"
            case .httpStream: return "🌨"
            case .fileStream: return "🌤"
            case .cachingStream: return "❄️"
            case .freePlayer: return "🍄"
            case .id3Parser: return "⚡️"
            }
        }

        static var All: Set<Module> { return [.audioQueue, .audioStream, .httpStream, .fileStream, .cachingStream, .freePlayer, .id3Parser] }
        
        fileprivate static var _lastMessage: String?
        func log(msg: String, method: String = #function) {
            if Module._lastMessage == msg { return }
            Module._lastMessage = msg
            let total = "\(self.symbolize)\(method):\(msg)"
//            #if (arch(i386) || arch(x86_64)) && os(iOS)//iPhone Simulator
                print(total)
//            #endif
            FPLogger.write(msg: total)
        }
        
        func condition(_ condition: Bool, message: String = "", method: String = #function) {
            if shared._modules.isEmpty || shared._modules.contains(self) == false { return }
            if condition == false { FPLogger.write(msg: method + ":" + message) }
            assert(condition, message)
        }
    }
    
    public mutating func save() {
        DispatchQueue.global(qos: .userInitiated).async {
            if FPLogger.shared.logToFile == false { return }
            let fs = FileManager.default
            if fs.fileExists(atPath: FPLogger.shared.logfile) == false {
                FPLogger.shared.lastRead = 0
                FPLogger.shared.logToFile = false
                FPLogger.shared.logToFile = true
            } else {
                FPLogger.shared.updateTime()
                FPLogger.shared.lastRead = FPLogger.shared.totalSize
                FPLogger.write(msg: "🎹:Freeplayer[\(FreePlayerVersion)]@\(FPLogger.shared._openTime)")
            }
        }
    }
    
    private mutating func updateTime() {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        fmt.locale = Locale.current
        let total = fmt.string(from: Date()).components(separatedBy: " ")
        _openTime = total.last ?? ""
    }
    private mutating func toggleEnableLog() {
        if logToFile {
            updateTime()
            DispatchQueue.global(qos: .userInitiated).async {
                UserDefaults.standard.set(FPLogger.shared.logToFile, forKey: "FreePlayer.LogToFile")
                UserDefaults.standard.synchronize()
            }
            let u = URL(fileURLWithPath: logfile)
            if access(logfile.withCString({$0}), F_OK) == -1 { // file not exists
                FileManager.default.createFile(atPath: logfile, contents: nil, attributes: nil)
            }
            _fileHandler = try? FileHandle(forWritingTo: u)
            if let fileHandle = _fileHandler {
                 lastRead = fileHandle.seekToEndOfFile()
            }
            totalSize = lastRead
            let msg = "🎹:Freeplayer[\(FreePlayerVersion)]@\(_openTime)"
            if let fileHandle = _fileHandler {
                _logQueue.sync {
                    guard let data = msg.data(using: String.Encoding.utf8) else { return }
                    totalSize += UInt64(data.count)
                    fileHandle.write(data)
                }
            }
        } else {
            guard let fileHandle = _fileHandler else { return }
            _logQueue.sync { fileHandle.closeFile() }
        }
    }
    
    static func write(msg: String) {
        guard let fileHandler = shared._fileHandler else { return }
        let total = msg + FPLogger.lineSeperator
        shared._logQueue.async {
            guard let data = total.data(using: .utf8) else { return }
            shared.totalSize += UInt64(data.count)
            fileHandler.write(data)
        }
    }
}

func as_log(_ msg: String, function: String = #function) {
    FPLogger.Module.audioStream.log(msg: msg, method: function)
}

func cs_log(_ msg: String, function: String = #function) {
    FPLogger.Module.cachingStream.log(msg: msg, method: function)
}

func hs_log(_ msg: String, function: String = #function) {
    FPLogger.Module.httpStream.log(msg: msg, method: function)
}

func aq_log(_ msg: String, method: String = #function) {
    FPLogger.Module.audioQueue.log(msg: msg, method: method)
}

func aq_assert(_ condition: Bool, message: String = "", method: String = #function) {
    FPLogger.Module.audioQueue.condition(condition, message: message, method: method)
}

func fp_log(_ msg: String, method: String = #function) {
    FPLogger.Module.freePlayer.log(msg: msg, method: method)
}

func id3_log(_ msg: String, method: String = #function) {
    FPLogger.Module.id3Parser.log(msg: msg, method: method)
}


func debug_log(_ msg: Any...) {
    #if DEBUG || ((arch(i386) || arch(x86_64)) && os(iOS))
        print(msg)
    #endif
}


func log_pointer(data: UnsafePointer<UInt8>, len: UInt32) {
    var array = [UInt8]()
    let l = Int(len)
    for i in 0..<l {
        array.append(data.advanced(by: i).pointee)
    }
    debug_log(array)
}
