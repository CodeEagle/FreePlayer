//
//  Extension.swift
//  FreePlayer
//
//  Created by Lincoln Law on 2017/2/20.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//

import Foundation

extension OSSpinLock {
    mutating func lock() { OSSpinLockLock(&self) }
    mutating func unlock() { OSSpinLockUnlock(&self) }
}

extension UnsafeMutableRawPointer {
    func to<T : AnyObject>(object: T.Type) -> T {
        return Unmanaged<T>.fromOpaque(self).takeUnretainedValue()
    }
    static func voidPointer<T: AnyObject>(from object: T) -> UnsafeMutableRawPointer {
        return Unmanaged<T>.passUnretained(object).toOpaque()
    }
}

extension OSStatus {
    private func humanErrorMessage(from raw: String) -> String {
        var result = ""
        switch raw {
        case "wht?": result = "Audio File Unspecified"
        case "typ?": result = "Audio File Unsupported File Type"
        case "fmt?": result = "Audio File Unsupported Data Format"
        case "pty?": result = "Audio File Unsupported Property"
        case "!siz": result = "Audio File Bad Property Size"
        case "prm?": result = "Audio File Permissions Error"
        case "optm": result = "Audio File Not Optimized"
        case "chk?": result = "Audio File Invalid Chunk"
        case "off?": result = "Audio File Does Not Allow 64Bit Data Size"
        case "pck?": result = "Audio File Invalid Packet Offset"
        case "dta?": result = "Audio File Invalid File"
        case "op??", "0x6F703F3F": result = "Audio File Operation Not Supported"
        case "!pkd": result = "Audio Converter Err Requires Packet Descriptions Error"
        case "-38": result = "Audio File Not Open"
        case "-39": result = "Audio File End Of File Error"
        case "-40": result = "Audio File Position Error"
        case "-43": result = "Audio File File Not Found"
        default: result = ""
        }
        result = "\(result)(\(raw))"
        return result
    }
    
    public func check(operation: String, file: String = #file, method: String = #function, line: Int = #line) {
        guard self != noErr else { return }
        
        var result: String = ""
        var char = Int(bigEndian)
        
        for _ in 0..<4 {
            guard isprint(Int32(char&255)) == 1 else {
                result = "\(self)"
                break
            }
            //UnicodeScalar(char&255) will get optional
            let raw = String(describing: UnicodeScalar(UInt8(char&255)))
            result += raw
            char = char/256
        }
        let humanMsg = humanErrorMessage(from: result)
        let msg = "\n{\n file: \(file):\(line),\n function: \(method),\n operation: \(operation),\n message: \(humanMsg)\n}"
        print(msg)
    }
}
