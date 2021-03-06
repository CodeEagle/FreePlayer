//
//  FileStream.swift
//  FreePlayer
//
//  Created by Lincoln Law on 2017/2/21.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//

import AudioToolbox

/// FileStream
final class FileStream {
    weak var delegate: StreamInputDelegate?
    private var _url: URL?
    private var _readStream: CFReadStream?
    private var _scheduledInRunLoop = false
    private var _readPending = false
    private var _contentType: String?
    private var _position = Position()
    private var _fileReadBuffer: UnsafeMutablePointer<UInt8>?
    private var _id3Parser: ID3Parser?
    deinit {
        close()
        _id3Parser = nil
        let config = StreamConfiguration.shared
        _fileReadBuffer?.deallocate(capacity: Int(config.httpConnectionBufferSize))
    }
    
    init() {
        _id3Parser = ID3Parser()
        _id3Parser?.delegate = self
    }
}

// MARK: - ID3ParserDelegate
extension FileStream: ID3ParserDelegate {
    func id3metaDataAvailable(metaData: [String : Metadata]) {
        delegate?.streamMetaDataAvailable(metaData: metaData)
    }
    
    func id3tagSizeAvailable(tag size: UInt32) {
        delegate?.streamMetaDataByteSizeAvailable(sizeInBytes: size)
    }
}
// MARK: - StreamInputProtocol
extension FileStream: StreamInputProtocol {
    
    var position: Position { return _position }
    
    var contentType: String {
        get {
            if let type = _contentType { return type }
            guard let lastComponent = _url?.lastPathComponent else { return "" }
            let contentTypes = [".mp3" : "mpeg",".m4a" : "x-m4a", ".aac" : "aac"]
            for (key, value) in contentTypes {
                if lastComponent.hasSuffix(key) { return "audio/\(value)" }
            }
            return "audio/mpeg"
        }
        set { _contentType = newValue }
    }
    
    var contentLength: UInt64 {
        guard let u = _url else { return 0 }
        var pError: Unmanaged<CFError>? = nil
        var pSize: CFNumber? = nil
        CFURLCopyResourcePropertyForKey(u as CFURL, kCFURLFileSizeKey, &pSize, &pError)
        if let size = pSize {
            return UInt64(truncating: size)
        }
        return  0
    }
    
    var errorDescription: String? { return nil }
    
    func open(_ position: Position) -> Bool {
        var success = false
        let this = UnsafeMutableRawPointer.voidPointer(from: self)
        var ctx = CFStreamClientContext(version: 0, info: this, retain: nil, release: nil, copyDescription: nil)
        func out() -> Bool {
            if success { delegate?.streamIsReadyRead() }
            return success
        }
        /* Already opened a read stream, return */
        if _readStream != nil { return out() }
        guard let url = _url else { return out() }
        
        /* Reset state */
        _position = position
        _readPending = false
        
        /* Failed to create a stream */
        _readStream = CFReadStreamCreateWithFile(kCFAllocatorDefault, url as CFURL)
        if _readStream == nil { return out() }

        if _position.start > 0 {
            let position = CFNumberCreate(kCFAllocatorDefault, .longLongType, &_position.start)
            CFReadStreamSetProperty(_readStream, CFStreamPropertyKey.fileCurrentOffset, position)
        }
        
        let flags = CFStreamEventType.hasBytesAvailable.rawValue | CFStreamEventType.endEncountered.rawValue | CFStreamEventType.errorOccurred.rawValue
        let result = CFReadStreamSetClient(_readStream, flags, FileStream.readCallBack, &ctx)
        if result == false { return out() }
        setScheduledInRunLoop(run: true)
        
        if !CFReadStreamOpen(_readStream) {
            /* Open failed: clean */
            CFReadStreamSetClient(_readStream, 0, nil, nil)
            setScheduledInRunLoop(run: false)
            _readStream = nil
            return out()
        }
        success = true
        _id3Parser?.detechV1(with: url, total: 0)
        return out()
    }
    
    func open() -> Bool {
        _id3Parser?.reset()
        return open(Position())
    }
    
    func close() {
        guard let readStream = _readStream else { return }
        CFReadStreamSetClient(readStream, 0, nil, nil)
        setScheduledInRunLoop(run: false)
        CFReadStreamClose(readStream)
        _readStream = nil
    }
    
    func setScheduledInRunLoop(run: Bool) {
        guard let readStream = _readStream else { return }
        if run == false {
            CFReadStreamUnscheduleFromRunLoop(readStream, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes)
        } else {
            if _readPending {
                _readPending = false
                let this = UnsafeMutableRawPointer.voidPointer(from: self)
                FileStream.readCallBack(readStream, CFStreamEventType.hasBytesAvailable, this)
            }
            CFReadStreamScheduleWithRunLoop(readStream, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes)
        }
        _scheduledInRunLoop = run
    }
    
    func set(url: URL) { _url = url }
}

// MARK: readCallBack
extension FileStream {
    static var readCallBack: CFReadStreamClientCallBack {
        return { stream, type, userData in
            guard let data = userData else { return }
            let fs = data.to(object: FileStream.self)
            let config = StreamConfiguration.shared
            
            func errorOccurred() {
                guard let error = CFReadStreamCopyError(stream), let desc = CFErrorCopyDescription(error) else { return }
                fs.delegate?.streamErrorOccurred(errorDesc: desc as String)
            }
            
            func hasBytesAvailable() {
                let size = Int(config.httpConnectionBufferSize)
                if fs._fileReadBuffer == nil {
                    fs._fileReadBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
                }
                
                while CFReadStreamHasBytesAvailable(stream) {
                    if fs._scheduledInRunLoop == false {
                        /*
                         * This is critical - though the stream has data available,
                         * do not try to feed the audio queue with data, if it has
                         * indicated that it doesn't want more data due to buffers
                         * full.
                         */
                        fs._readPending = true
                        break
                    }
                    let bytesRead = CFReadStreamRead(stream, fs._fileReadBuffer, size)
                    if CFReadStreamGetStatus(stream) == CFStreamStatus.error || bytesRead < 0 {
                        errorOccurred()
                    }
                    if bytesRead > 0, let buffer = fs._fileReadBuffer {
                        let len = UInt32(bytesRead)
                        fs.delegate?.streamHasBytesAvailable(data: buffer, numBytes: len)
                        if fs._id3Parser?.wantData() == true {
                            fs._id3Parser?.feedData(data: buffer, numBytes: len)
                        }
                    }
                }
            }
            func endEncountered() { fs.delegate?.streamEndEncountered() }
            switch type {
            case CFStreamEventType.hasBytesAvailable: hasBytesAvailable()
            case CFStreamEventType.endEncountered: endEncountered()
            case CFStreamEventType.errorOccurred: errorOccurred()
            default: break
            }
            
        }
    }
}

// MARK: canHandleURL
extension FileStream {
    static func canHandle(url: URL?) -> Bool {
        guard let u = url else { return false }
        return u.scheme == "file"
    }
}
