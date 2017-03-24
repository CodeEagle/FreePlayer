//
//  CachingStream.swift
//  FreePlayer
//
//  Created by Lincoln Law on 2017/2/21.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//

import AudioToolbox

/// CachingStream
final class CachingStream {
    // MARK: StreamInputProtocol
    weak var delegate: StreamInputDelegate?
    var position: Position {
        return _useCache ? _fileStream.position : _target.position
    }
    var contentType: String {
        return _useCache ? _fileStream.contentType : _target.contentType
    }
    var contentLength: UInt64 {
        return _useCache ? _fileStream.contentLength : _target.contentLength
    }
    var errorDescription: String?
    
    var cachedComplete = false
    
    fileprivate var _target: StreamInputProtocol
    fileprivate var _fileOutput: StreamOutputManager?
    fileprivate var _fileStream: FileStream
    fileprivate var _cacheable = false
    fileprivate var _writable = false
    fileprivate var _useCache = false
    fileprivate var _cacheMetaDataWritten = false
    fileprivate var _cacheIdentifier: String?
    fileprivate var _storeIdentifier: String?
    fileprivate var _fileUrl: URL?
    fileprivate var _metaDataUrl: URL?
    
    deinit {
        _fileOutput = nil
        _cacheIdentifier = nil
        _fileUrl = nil
        _metaDataUrl = nil
    }
    
    init(target: StreamInputProtocol) {
        _target = target
        _fileStream = FileStream()
        _target.delegate = self
        _fileStream.delegate = self
    }
    
}

// MARK: Utils
extension CachingStream {
    
    fileprivate func createFileURL(with path: String?) -> URL? {
        guard let p = path else { return nil }
        let escapePath = p.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        return URL(fileURLWithPath: escapePath ?? p)
    }
    
    fileprivate func readMetaData() {
        guard let url = _metaDataUrl else { return }
        guard let stream = CFReadStreamCreateWithFile(kCFAllocatorDefault, url as CFURL) else { return }
        guard CFReadStreamOpen(stream) else { return }
        var buf: [UInt8] = Array(repeating: 0, count: 1024)
        let bytesRead = CFReadStreamRead(stream, &buf, 1024)
        if bytesRead > 0 {
            guard let type = String(bytes: buf, encoding: .utf8) else { return }
            cs_log("Setting the content type [\(type)] of the file stream based on the meta data")
            _fileStream.contentType = contentType
        }
        CFReadStreamClose(stream)
    }
    
    func setStoreIdentifier(id: String) -> Bool {
        _storeIdentifier = id
        _fileOutput = nil
        let config = StreamConfiguration.shared
        guard let storeFolder = config.storeDirectory else {
            cs_log("no config.storeDirectory:\(config.storeDirectory)")
            return false
        }
        
        let filePath = (storeFolder as NSString).appendingPathComponent(id)
        let metaDataPath = (storeFolder as NSString).appendingPathComponent(id + ".metadata")
        
        let buffer = filePath.withCString{ $0 }
        var b: stat = stat()
        let hasFile = stat(buffer, &b) == 0
        if !hasFile {
            cs_log("no file:\(filePath) at:\(config.storeDirectory)")
            return false
        }
        
        guard let url = createFileURL(with: filePath) else {
            cs_log("createFileURL:\(filePath) fail")
            return false
        }
        _fileUrl = url
        _metaDataUrl = createFileURL(with: metaDataPath)
        _fileStream.set(url: url)
        cs_log("success")
        return true
    }
    
    func setCacheIdentifier(id: String) {
        _cacheIdentifier = id
        _fileOutput = nil
        let config = StreamConfiguration.shared
        let cacheFolder = config.cacheDirectory
        let filePath = (cacheFolder as NSString).appendingPathComponent(id)
        let metaDataPath = (cacheFolder as NSString).appendingPathComponent(id + ".metadata")
        
        let buffer = metaDataPath.withCString{ $0 }
        var b: stat = stat()
        let hasFile = stat(buffer, &b) == 0
        cachedComplete = hasFile
        
        guard let url = createFileURL(with: filePath) else { return }
        _fileUrl = url
        _metaDataUrl = createFileURL(with: metaDataPath)
        _fileStream.set(url: url)
    }
    
    static func canHandleUrl(url: URL?) -> Bool {
        return true
    }
}
// MARK: StreamInputProtocol
extension CachingStream: StreamInputProtocol {
    
    @discardableResult public func open(_ position: Position) -> Bool {
        var status = false
        if let meta = _metaDataUrl, CFURLResourceIsReachable(meta as CFURL, nil), let file = _fileUrl, CFURLResourceIsReachable(file as CFURL, nil) {
            _cacheable = false
            _writable  = false
            _useCache  = true
            _cacheMetaDataWritten = false
            
            readMetaData()
            cs_log("Playing file from cache")
            cs_log("file:\(file)")
            status = _fileStream.open(position)
        } else {
            _cacheable = false
            _writable  = false
            _useCache  = false
            _cacheMetaDataWritten = false
            cs_log("File not cached")
            status = _target.open(position)
        }
        return status
    }
    
    @discardableResult public func open() -> Bool {
        
        var status = false
        if let meta = _metaDataUrl, CFURLResourceIsReachable(meta as CFURL, nil), let file = _fileUrl, CFURLResourceIsReachable(file as CFURL, nil) {
            _cacheable = false
            _writable  = false
            _useCache  = true
            _cacheMetaDataWritten = false
            readMetaData()
            cs_log("Playing file from cache")
            status = _fileStream.open()
        } else {
            _cacheable = true
            _writable  = false
            _useCache  = false
            _cacheMetaDataWritten = false
            status = _target.open()
        }
        return status
    }
    
    public func close() {
        _fileStream.close()
        _target.close()
    }
    
    public func setScheduledInRunLoop(run: Bool) {
        _useCache ? _fileStream.setScheduledInRunLoop(run: run) : _target.setScheduledInRunLoop(run: run)
    }
    
    public func set(url: URL) { _target.set(url: url) }
}

// MARK: - StreamInputDelegate
extension CachingStream: StreamInputDelegate {
    public func streamIsReadyRead() {
        if _cacheable {
            // If the stream is cacheable (not seeked from some position)
            // Check if the stream has a length. If there is no length,
            // it is a continuous stream and thus cannot be cached.
            _cacheable = _target.contentLength > 0
        }
        delegate?.streamIsReadyRead()
    }
    
    public func streamHasBytesAvailable(data: UnsafePointer<UInt8>, numBytes: UInt32) {
        if _cacheable {
            guard numBytes > 0 else { return }
            if _fileOutput == nil, let url = _fileUrl  {
                cs_log("Caching started for stream")
                _fileOutput = StreamOutputManager(fileURL: url)
                _writable = true
            }
            if _writable, let out = _fileOutput {
                _writable = out.write(data: data, length: Int(numBytes)) && _writable
            }
        }
        delegate?.streamHasBytesAvailable(data: data, numBytes: numBytes)
    }
    
    public func streamEndEncountered() {
        _fileOutput = nil
        if _cacheable, _writable {
            cs_log("Successfully cached the stream\n:\(_fileUrl!)")
            // We only write the meta data if the stream was successfully streamed.
            // In that way we can use the meta data as an indicator that there is a file to stream.
            if !_cacheMetaDataWritten, let url = _metaDataUrl  {
                cs_log("Writing the meta data")
                let contentType = _target.contentType
                do {
                    try contentType.data(using: .utf8)?.write(to: url)
                } catch {
                    cs_log("Writing the meta data error:\(error)")
                }
                _cacheable = false
                _writable  = false
                _useCache  = true
                _cacheMetaDataWritten = true
            }
        }
        delegate?.streamEndEncountered()
    }
    
    public func streamErrorOccurred(errorDesc: String) {
        delegate?.streamErrorOccurred(errorDesc: errorDesc)
    }
    
    public func streamMetaDataAvailable(metaData: [String: Metadata]) {
        delegate?.streamMetaDataAvailable(metaData: metaData)
    }
    
    public func streamMetaDataByteSizeAvailable(sizeInBytes: UInt32) {
        delegate?.streamMetaDataByteSizeAvailable(sizeInBytes: sizeInBytes)
    }
    
    public func streamHasDataCanPlay() -> Bool {
        return delegate?.streamHasDataCanPlay() ?? false
    }
}
