//
//  FileOutPutProtocol.swift
//  FreePlayer
//
//  Created by Lincoln Law on 2017/2/19.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//

import Foundation

/// 数据存储管理
final class StreamOutputManager {
    
    private var _writeStream: CFWriteStream?
    
    deinit {
        guard let stream = _writeStream else { return }
        CFWriteStreamClose(stream)
    }
    
    init(fileURL: URL) {
        let stream = CFWriteStreamCreateWithFile(kCFAllocatorDefault, fileURL as CFURL)
        CFWriteStreamOpen(stream)
        _writeStream = stream
    }
    
    @discardableResult func write(data: UnsafePointer<UInt8>, length: Int) -> Bool {
        guard let stream = _writeStream else { return false }
        let result = CFWriteStreamWrite(stream, data, length)
        return result != -1
    }
}

