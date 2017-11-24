//
//  StreamProvider.swift
//  StreamDeocoder
//
//  Created by lincolnlaw on 2017/9/15.
//  Copyright © 2017年 lincolnlaw. All rights reserved.
//

import Foundation
import AudioToolbox
/**
 StreamProvider
 实现功能
 1. 获取http(s) stream
 2. 获取local file stream
 3. 根据文件名，推测文件类型，得出filehint
 4. 文件大小
 */
//

protocol StreamInputProtocol {
    weak var delegate: StreamInputDelegate? { get set }
    var position: Position { get }
    var fileHint: AudioFileTypeID? { get }
    var contentLength: UInt { get }
    var errorDescription: String? { get }
    
    @discardableResult func open(at position: Position) -> Bool
    @discardableResult func open() -> Bool
    func close()
    func setScheduledInRunLoop(run: Bool)
    init(url: URL)
}

public protocol StreamInputDelegate: class {
    func streamIsReadyRead()
    func streamHasBytesAvailable(data: UnsafePointer<UInt8>, numBytes: UInt32)
    func streamEndEncountered()
    func streamErrorOccurred(errorDesc: String)
    func streamMetaDataAvailable(metaData: [MetaDataKey: Metadata])
    func streamMetaDataByteSizeAvailable(sizeInBytes: UInt32)
    func streamHasDataCanPlay() -> Bool
}
extension StreamProvider: StreamInputProtocol {
    
    var fileHint: AudioFileTypeID? { return info.fileHint }
    
    @discardableResult func open() -> Bool {
        return open(at: Position())
    }
    
    func close() {
        close(resetTimer: true)
    }
    
}
public final class StreamProvider {
    static let ErrorPrefix = "[❌]"

    public weak var delegate: StreamInputDelegate?
    public lazy var autoProduce = true
    public private(set) var info: URLInfo
    public private(set) var contentLength: UInt = 0
    public private(set) lazy var position: Position = Position()
    public private(set) lazy var errorDescription: String? = nil

    private lazy var _queue = RunloopQueue(named: "StreamProvider.Schedule")
//    private lazy var _runloop = RunLoop.current.getCFRunLoop()
    private lazy var _readStream: CFReadStream? = nil
    private lazy var _isRemoteStreamCacheEnabled = true
    private lazy var _isScheduledingRunLoop = false
    private lazy var _id3Parser: ID3Parser? = nil
    private lazy var _readPending = false
    
    // MARK: http
    private lazy var _bytesRead: UInt = 0
    private var _httpHeadersParsed = false
    private lazy var _parsingQueue = DispatchQueue(label: "parsing")

    // MARK: ICY protocol
    private lazy var _icyName: String? = nil
    private lazy var _icyStream = false
    private lazy var _icyHeaderCR = false
    private lazy var _icyHeadersRead = false
    private lazy var _icyHeadersParsed = false
    private lazy var _icyHeaderLines: [String] = []
    private lazy var _icyMetaDataInterval = 0
    private lazy var _dataByteReadCount = 0
    private lazy var _metaDataBytesRemaining = 0
    private lazy var _icyMetaData: [UInt8] = []

    // MARK: read buffers
    private lazy var _readBuffer: UnsafeMutablePointer<UInt8>! = malloc(Int(self._readBufferSize))!.assumingMemoryBound(to: UInt8.self)
    private lazy var _readBufferSize: UInt = StreamConfiguration.shared.httpConnectionBufferSize
    private lazy var _icyReadBuffer: [UInt8]? = nil

    // MARK: http proxy
    private lazy var _auth: CFHTTPAuthentication? = nil
    private lazy var _credentials: [String: String]? = nil

    // MARK: http open retry
    private lazy var _openTimer: CFRunLoopTimer? = nil
    private lazy var _reopenTimes: UInt = 0
    private lazy var _isReadedData = false
    
    // MARK: cache
    private lazy var _cacheName: String? = {
        guard StreamConfiguration.shared.cachePolicy.isEnabled else { return nil }
        let url = self.info.url
        let name = StreamConfiguration.shared.cacheNaming.name(for: url)
        return name
    }()
    
    private lazy var _cacheWritePath: String? = {
        guard let name = self._cacheName else { return nil }
        return "\(StreamConfiguration.shared.cacheDirectory)/\(name)"
    }()
    
    private lazy var _cacheWriteTmpPath: String? = {
        guard let name = self._cacheWritePath else { return nil }
        return "\(name).tmp"
    }()
    
    private lazy var _filehandle: UnsafeMutablePointer<FILE>? = {
        guard let tmp = self._cacheWriteTmpPath else { return nil }
        return fopen(tmp, "w+")
    }()
    
    private lazy var _fileWritten: UInt = 0
    
    deinit {
        _id3Parser = nil
        if let buffer = _readBuffer { free(buffer) }
        if info.isRemote {
            _icyMetaData.removeAll()
            _auth = nil
            _credentials = nil
            _icyReadBuffer?.removeAll()
        }
        print("StreamProvider deinit")
    }

    public init(url: URL) {
        let i = URLInfo.from(url: url)
        info = i
        if let cachedURL = cachedFileURL() {
            info = cachedURL
            print("read from cached")
        }
        if info.isWave == false {
            _id3Parser = ID3Parser()
            _id3Parser?.delegate = self
        }
        getLocalContentLength()
    }

    private func cachedFileURL() -> URLInfo? {
        guard let name = self._cacheName else { return nil }
        let fs = FileManager.default
        let defaultFile = "\(StreamConfiguration.shared.cacheDirectory)/\(name)"
        var url: URL?
        if fs.fileExists(atPath: defaultFile) {
             url = URL(fileURLWithPath: defaultFile)
        }
        if case .enableAndSearching(let dir) = StreamConfiguration.shared.cachePolicy {
            let extra = "\(dir)/\(name)"
            if fs.fileExists(atPath: extra) {
                 url = URL(fileURLWithPath: extra)
            }
        }
        guard let u = url else { return nil }
        return URLInfo.from(url: u)
    }
    
    @discardableResult public func open(at position: Position) -> Bool {
        guard _readStream == nil else { return false }
        _id3Parser?.reset()
        // continue write data if start postion == _fileWritten
        if position.start != _fileWritten, let handle = _filehandle {
            fclose(handle)
            _filehandle = nil
        }
        self.position = position
        createStream()
        guard let stream = _readStream else { return false }
        let this = UnsafeMutableRawPointer.from(object: self)
        var ctx = CFStreamClientContext(version: 0, info: this, retain: nil, release: nil, copyDescription: nil)
        let flags: CFStreamEventType = [.hasBytesAvailable, .endEncountered, .errorOccurred]
        let callback: CFReadStreamClientCallBack = { _, type, userData in
            guard let data = userData else { return }
            let fs = data.to(object: StreamProvider.self)
            fs.readCallBack(type: type)
        }
        guard CFReadStreamSetClient(stream, flags.rawValue, callback, &ctx) == true else {
            _readStream = nil
            return false
        }
        setScheduledInRunLoop(run: true)
        guard CFReadStreamOpen(stream) == true else {
            CFReadStreamSetClient(stream, 0, nil, nil)
            setScheduledInRunLoop(run: false)
            _readStream = nil
            return false
        }
        if info.isRemote {
            if _reopenTimes < StreamConfiguration.shared.maxRemoteStreamOpenRetry {
                _reopenTimes += 1
                _isReadedData = false
            }
        } else {
            delegate?.streamIsReadyRead()
        }
        return true
    }

    func close(resetTimer: Bool = true) {
        guard let stream = _readStream else { return }
        CFReadStreamSetClient(stream, 0, nil, nil)
        setScheduledInRunLoop(run: false)
        CFReadStreamClose(stream)
        _readStream = nil
        guard info.isRemote else { return }
        if resetTimer { resetRetryWatchDog(resetFlag: true) }
    }
    
    func setScheduledInRunLoop(run: Bool) {
        guard let readStream = _readStream else { return }
        if run == false {
            _queue.unschedule(readStream)
//            CFReadStreamUnscheduleFromRunLoop(readStream, _runloop, .commonModes)
        } else {
//            CFReadStreamScheduleWithRunLoop(readStream, _runloop, .commonModes)
            _queue.schedule(readStream)
        }
        _isScheduledingRunLoop = run
    }

    /// read
    ///
    /// - Parameters:
    ///   - bytes: need free when done using it
    ///   - count: pass size you want to read
    public func read(bytes: UnsafeMutablePointer<UInt8>, count: UInt) -> UInt {
        guard let stream = _readStream, CFReadStreamHasBytesAvailable(stream) else { return 0 }
        let size = Int(count)
        let bytesRead = CFReadStreamRead(stream, bytes, size)
        guard bytesRead > 0 else { return 0 }
        if info.isRemote {
            if CFReadStreamGetStatus(stream) == CFStreamStatus.error || bytesRead < 0 {
                if contentLength > 0 {
                    var p = Position()
                    p.start = position.start + _bytesRead
                    resetRetryWatchDog(resetFlag: true)
                    open(at: p)
                    return 0
                }
                handleStreamError()
                return 0
            }
            _parsingQueue.sync {
                self.parseHttpHeadersIfNeeded(buffer: bytes, bufSize: bytesRead)
                self.write(bytes: bytes, count: UInt(bytesRead))
                if self._icyStream {
                    print("Parsing ICY stream")
                    self.parseICYStream(buffers: bytes, bufSize: bytesRead)
                }
            }
        }
        _bytesRead += UInt(bytesRead)
        if _id3Parser?.wantData() == true, _icyStream == false {
            _id3Parser?.feedData(data: bytes, numBytes: UInt32(bytesRead))
        }
        return UInt(bytesRead)
    }
}

private extension StreamProvider {
    func getLocalContentLength() {
        guard case let URLInfo.local(url, _) = info else { return }
        var name = url.absoluteString.replacingOccurrences(of: "file://", with: "")
        if let value = name.removingPercentEncoding { name = value }
        let path = name.withCString({ $0 })
        guard let file = fopen(path, "rb") else { return }
        defer { fclose(file) }
        fseek(file, 0, SEEK_END)
        contentLength = UInt(ftell(file))
    }

    func createStream() {
        switch info {
        case let .local(url, _): createLocalStream(for: url)
        case let .remote(url, _): createRemoteStream(for: url)
        default: return
        }
    }

    func createLocalStream(for url: URL) {
        _readStream = CFReadStreamCreateWithFile(kCFAllocatorDefault, url as CFURL)
        guard let stream = _readStream else { return }
        if position.start > 0 {
            let p = CFNumberCreate(kCFAllocatorDefault, .longLongType, &position)
            CFReadStreamSetProperty(stream, CFStreamPropertyKey.fileCurrentOffset, p)
        }
        return
    }

    func createRemoteStream(for url: URL) {
        var config = StreamConfiguration.shared
        let request = CFHTTPMessageCreateRequest(kCFAllocatorDefault, Keys.get.cf, url as CFURL, kCFHTTPVersion1_1).takeRetainedValue()
        if let ua = config.userAgent {
            CFHTTPMessageSetHeaderFieldValue(request, Keys.userAgent.cf, ua as CFString)
        }
        CFHTTPMessageSetHeaderFieldValue(request, Keys.icyMetadata.cf, Keys.icyMetaDataValue.cf)

        if position.start > 0 {
            let range = "bytes=\(position.start)-" as CFString
            CFHTTPMessageSetHeaderFieldValue(request, Keys.range.cf, range)
        }

        for (key, value) in config.predefinedHttpHeaderValues {
            print("Setting predefined HTTP header[\(key) : \(value)]")
            CFHTTPMessageSetHeaderFieldValue(request, key as CFString, value as CFString)
        }

        if let authentication = _auth, let info = _credentials {
            let credentials = info as CFDictionary
            if CFHTTPMessageApplyCredentialDictionary(request, authentication, credentials, nil) == false {
                delegate?.streamErrorOccurred(errorDesc: "add authentication fail")
                return
            }
            print("digest authentication add success")
        }
        let s = CFReadStreamCreateForHTTPRequest(kCFAllocatorDefault, request)
        let stream = s.takeRetainedValue()
        CFReadStreamSetProperty(stream, CFStreamPropertyKey(rawValue: kCFStreamNetworkServiceType), kCFStreamNetworkServiceTypeBackground)
        CFReadStreamSetProperty(stream, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPShouldAutoredirect), kCFBooleanTrue)

        if case let StreamConfiguration.ProxyPolicy.custom(info) = config.proxyPolicy {
            var dict: [String: Any] = [:]
            dict[kCFNetworkProxiesHTTPPort as String] = info.port
            dict[kCFNetworkProxiesHTTPProxy as String] = info.host
            let proxy = dict as CFDictionary
            if CFReadStreamSetProperty(stream, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPProxy), proxy) == false {
                print("setting custom proxy not success")
            }
        } else {
            if let proxy = CFNetworkCopySystemProxySettings()?.takeRetainedValue() {
                let dict = proxy as NSDictionary
                print("system proxy:\(dict)")
                CFReadStreamSetProperty(stream, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPProxy), proxy)
            }
        }
        // SSL Support
        if url.scheme?.lowercased() == "https" {
            let sslSettings: [String: Any] = [
                kCFStreamSocketSecurityLevelNegotiatedSSL as String: false,
                kCFStreamSSLLevel as String: kCFStreamSSLValidatesCertificateChain,
                kCFStreamSSLPeerName as String: NSNull(),
            ]
            let key = CFStreamPropertyKey(rawValue: kCFStreamPropertySSLSettings)
            CFReadStreamSetProperty(stream, key, sslSettings as CFTypeRef)
        }
        _readStream = stream
        return
    }

   

    func readCallBack(type: CFStreamEventType) {
        func hasBytes() {
            if info.isRemote {
                resetRetryWatchDog(resetFlag: true)
                _isReadedData = true
            }
            guard autoProduce == true else { return }
            guard let stream = _readStream else { return }
            while CFReadStreamHasBytesAvailable(stream) {
                /*
                 * This is critical - though the stream has data available,
                 * do not try to feed the audio queue with data, if it has
                 * indicated that it doesn't want more data due to buffers
                 * full.
                 */
                if _isScheduledingRunLoop == false {
                    _readPending = true
                    print("_readPending")
                    break
                }
                let bytesRead = CFReadStreamRead(stream, _readBuffer, CFIndex(_readBufferSize))
                
                guard bytesRead > 0 else { break }
                if info.isRemote {
                    if CFReadStreamGetStatus(stream) == CFStreamStatus.error {
                        if contentLength > 0 {
                            var p = Position()
                            p.start = position.start + _bytesRead
                            resetRetryWatchDog(resetFlag: true)
                            open(at: p)
                            break
                        }
                        handleStreamError()
                        break
                    }
                    _parsingQueue.sync {
                        self.parseHttpHeadersIfNeeded(buffer: self._readBuffer, bufSize: bytesRead)
                        self.write(bytes: self._readBuffer, count: UInt(bytesRead))
                        if self._icyStream {
                            print("Parsing ICY stream")
                            self.parseICYStream(buffers: self._readBuffer, bufSize: bytesRead)
                        }
                    }
                }
                _bytesRead += UInt(bytesRead)
                if _icyStream == false {
                    if _id3Parser?.wantData() == true {
                        _id3Parser?.feedData(data: self._readBuffer, numBytes: UInt32(bytesRead))
                    }
                    delegate?.streamHasBytesAvailable(data: self._readBuffer, numBytes: UInt32(bytesRead))
                }
            }
        }
        switch type {
        case CFStreamEventType.hasBytesAvailable: hasBytes()
        case CFStreamEventType.endEncountered:
            if info.isRemote {
                if let stream = _readStream, let myResponse = CFReadStreamCopyProperty(stream, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPResponseHeader)) {
                    let code = CFHTTPMessageGetResponseStatusCode(myResponse as! CFHTTPMessage)
                    if code == 401 { return }
                }
                let read = _bytesRead + position.start
                if read < contentLength {
                    print("HTTP stream endEncountered when not all content[\(contentLength)] stream, restart with postion \(read)")
                    startRetryWatchDog(with: 0.5)
                } else {
                    resetRetryWatchDog(resetFlag: true)
                    delegate?.streamEndEncountered()
                    self._parsingQueue.sync {
                        self.saveCachedBytes()
                    }
                }
            } else {
                delegate?.streamEndEncountered()
            }
        case CFStreamEventType.errorOccurred: handleStreamError()
        default: break
        }
    }

    func handleStreamError() {
        if let stream = _readStream, let err = CFReadStreamCopyError(stream), let desc = CFErrorCopyDescription(err) {
            errorDescription = desc as String
        }
        guard info.isRemote else { return }
        resetRetryWatchDog(resetFlag: true)
        guard let de = delegate, let e = errorDescription else { return }
        if de.streamHasDataCanPlay() == false { de.streamErrorOccurred(errorDesc: e) }
        else { startRetryWatchDog(with: 2) }
    }
    
}
// MARK: cache
private extension StreamProvider {
    
    func write(bytes: UnsafeRawPointer, count: UInt) {
        guard let fileHandle = _filehandle, _icyStream == false else { return }
        let written = fwrite(bytes, 1, Int(count), fileHandle)
        guard written > 0 else { return }
        _fileWritten += UInt(written)
    }
    
    func saveCachedBytes() {
        guard _fileWritten == contentLength, let tmp = _cacheWriteTmpPath, let target = _cacheWritePath, _icyStream == false else { return }
        let fs = FileManager.default
        do {
            try fs.moveItem(atPath: tmp, toPath: target)
            print("save in \(target)")
        } catch {
            print("\(#function):\(error)")
        }
    }
}

// MARK: http stream open retry
private extension StreamProvider {

    func resetRetryWatchDog(resetFlag: Bool) {
        if let timer = _openTimer { CFRunLoopTimerInvalidate(timer) }
        _reopenTimes = 0
        if resetFlag { _isReadedData = false }
    }

    func startRetryWatchDog(with interval: TimeInterval) {
        if let timer = _openTimer { CFRunLoopTimerInvalidate(timer) }
        let this = UnsafeMutableRawPointer.from(object: self)
        var ctx = CFRunLoopTimerContext(version: 0, info: this, retain: nil, release: nil, copyDescription: nil)
        let callback: CFRunLoopTimerCallBack = { _, info in
            guard let raw = info else { return }
            let sself = raw.to(object: StreamProvider.self)
            sself.retryWatchDogCallback()
        }
        guard let timer = CFRunLoopTimerCreate(nil, CFAbsoluteTimeGetCurrent() + interval, interval, 0, 0, callback, &ctx) else { return }
//        CFRunLoopAddTimer(_runloop, timer, .commonModes)
        _queue.addTimer(timer)
        _openTimer = timer
    }

    func retryWatchDogCallback() {
        if errorDescription != nil {
            close(resetTimer: false)
            var p = Position()
            p.start = position.start + _bytesRead
            guard p.start < contentLength else {
                if let timer = _openTimer { CFRunLoopTimerInvalidate(timer) }
                return
            }
            open(at: p)
        } else {
            if let timer = _openTimer { CFRunLoopTimerInvalidate(timer) }
            if _isReadedData == false { open(at: position) }
            else if position.start + _bytesRead < contentLength, contentLength > 0 {
                var p = Position()
                p.start = position.start + _bytesRead
                close()
                open(at: p)
            }
        }
    }
}

// MARK: - ID3ParserDelegate
extension StreamProvider: ID3ParserDelegate {
    func id3tagParsingDone() {
        _id3Parser = nil
    }
    
    func id3metaDataAvailable(metaData: [MetaDataKey: Metadata]) {
        delegate?.streamMetaDataAvailable(metaData: metaData)
    }

    func id3tagSizeAvailable(tag size: UInt32) {
        delegate?.streamMetaDataByteSizeAvailable(sizeInBytes: size)
    }
}

// MARK: parse Http Header
private extension StreamProvider {
    func parseHttpHeadersIfNeeded(buffer: UnsafeMutablePointer<UInt8>, bufSize: Int) {
        if _httpHeadersParsed { return }
        guard let readStream = _readStream else { return }
        _httpHeadersParsed = true

        if bufSize >= 10 {
            var datas = [UInt8]()
            // HTTP/1.0 200 OK
            /* If the response has the "ICY 200 OK" string,
             * we are dealing with the ShoutCast protocol.
             * The HTTP headers won't be available.
             */
            var icy = ""
            for i in 0 ..< 4 {
                let buf = buffer.advanced(by: i).pointee
                datas.append(buf)
            }
            var data = Data(bytes: datas)
            icy = String(data: data, encoding: .ascii) ?? ""
            for i in 4 ..< 10 {
                let buf = buffer.advanced(by: i).pointee
                datas.append(buf)
            }
            data = Data(bytes: datas)
            icy = String(data: data, encoding: .ascii) ?? ""
            // This is an ICY stream, don't try to parse the HTTP headers
            if icy.lowercased() == "icy 200 ok" { return }
        }

        print("A regular HTTP stream")

        guard let resp = CFReadStreamCopyProperty(readStream, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPResponseHeader)) else { return }
        let response = resp as! CFHTTPMessage
        var statusCode = 0

        /*
         * If the server responded with the icy-metaint header, the response
         * body will be encoded in the ShoutCast protocol.
         */
        let icyMetaIntString = CFHTTPMessageCopyHeaderFieldValue(response, Keys.icyMetaint.cf)?.takeRetainedValue()
        let icyNotice1String = CFHTTPMessageCopyHeaderFieldValue(response, Keys.icyNotice1.cf)?.takeRetainedValue()
        if let meta = icyMetaIntString {
            _icyStream = true
            _icyHeadersParsed = true
            _icyHeadersRead = true
            _icyMetaDataInterval = Int(CFStringGetIntValue(meta))
        } else if icyNotice1String != nil {
            _icyStream = true
            _icyHeadersParsed = true
            _icyHeadersRead = true
        }
        print("\(Keys.icyMetaint.rawValue): \(_icyMetaDataInterval)")

        statusCode = CFHTTPMessageGetResponseStatusCode(response)
        print("HTTP response code: \(statusCode)")

        let icyNameString = CFHTTPMessageCopyHeaderFieldValue(response, Keys.icyName.cf)?.takeRetainedValue()
        if let name = icyNameString {
            let n = name as String
            _icyName = n
            delegate?.streamMetaDataAvailable(metaData: [.title : .text(n)])
        }
        let ctype = CFHTTPMessageCopyHeaderFieldValue(response, Keys.contentType.cf)?.takeRetainedValue()
        if let contentType = ctype as String? {
            if case let .remote(url, hint) = info {
                let newHint = URLInfo.fileHint(from: contentType)
                if newHint != hint { info = .remote(url, newHint) }
            }
            print("\(Keys.contentType.rawValue): \(contentType)")
        }

        let status200 = statusCode == 200
        let serverError = 500 ... 599
        let clen = CFHTTPMessageCopyHeaderFieldValue(response, Keys.contentLength.cf)?.takeRetainedValue()
        if let len = clen, status200 {
            contentLength = UInt(UInt64(CFStringGetIntValue(len)))
            print("contentLength:\(contentLength)")
            _id3Parser?.detechV1(with: info.url, total: contentLength)
        }
        if status200 || statusCode == 206 {
            delegate?.streamIsReadyRead()
        } else {
        if [401, 407].contains(statusCode) {
            let responseHeader = CFReadStreamCopyProperty(readStream, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPResponseHeader)) as! CFHTTPMessage
            // Get the authentication information from the response.
            let authentication = CFHTTPAuthenticationCreateFromResponse(nil, responseHeader).takeRetainedValue()
            // <CFHTTPAuthentication 0x1703e1100>{state = InProgress; scheme = Digest, forProxy = false}
            if CFHTTPAuthenticationRequiresUserNameAndPassword(authentication) {
                if case let .custom(info) = StreamConfiguration.shared.proxyPolicy {
                    var credentials: [String: String] = [:]
                    credentials[kCFHTTPAuthenticationUsername as String] = info.username
                    credentials[kCFHTTPAuthenticationPassword as String] = info.password
                    _credentials = credentials
                    _auth = authentication
                }
            }
            print("did recieve authentication challenge")
            resetRetryWatchDog(resetFlag: true)
            startRetryWatchDog(with: 0.5)
            } else if serverError.contains(statusCode) {
                print("server error:\(statusCode)")
                resetRetryWatchDog(resetFlag: true)
                startRetryWatchDog(with: 0.5)
            } else {
                delegate?.streamErrorOccurred(errorDesc: "\(StreamProvider.ErrorPrefix)\(statusCode)")
            }
        }
    }

    func parseICYStream(buffers pointer: UnsafeMutablePointer<UInt8>, bufSize: Int) {
        print("Parsing an IceCast stream, received \(bufSize) bytes")
        var offset = 0
        var bytesFound = 0
        let buffers = malloc(bufSize)!.assumingMemoryBound(to: UInt8.self)
        defer { free(buffers) }
        memcpy(buffers, pointer, bufSize)
        func readICYHeader() {
            print("ICY headers not read, reading")
            while offset < bufSize {
                let buffer = buffers.advanced(by: offset).pointee
                let bufferString = String(Character(UnicodeScalar(buffer)))
                if bufferString == "", _icyHeaderCR {
                    if bytesFound > 0 {
                        var bytes: [UInt8] = []
                        let total = offset - bytesFound
                        for i in 0 ..< total {
                            bytes.append(buffers.advanced(by: i).pointee)
                        }
                        if let line = createMetaData(from: &bytes, numBytes: total) {
                            _icyHeaderLines.append(line)
                            print("_icyHeaderLines:\(line)")
                        }
                        bytesFound = 0
                        offset += 1
                        continue
                    }
                    _icyHeadersRead = true
                    break
                }
                if bufferString == "\r" {
                    _icyHeaderCR = true
                    offset += 1
                    continue
                } else {
                    _icyHeaderCR = false
                }
                bytesFound += 1
                offset += 1
            }
        }

        func parseICYHeader() {
            let icyContentTypeHeader = Keys.contentType.rawValue + ":"
            let icyMetaDataHeader = Keys.icyMetaint.rawValue + ":"
            let icyNameHeader = Keys.icyName.rawValue + ":"
            for line in _icyHeaderLines {
                if line.isEmpty { continue }
                let l = line.lowercased()
                if l.hasPrefix(icyContentTypeHeader) {
                    let contentType = line.replacingOccurrences(of: icyContentTypeHeader, with: "")
                    if case let .remote(url, hint) = info {
                        let newHint = URLInfo.fileHint(from: contentType)
                        if newHint != hint { info = .remote(url, newHint) }
                    }
                    print("\(Keys.contentType.rawValue): \(contentType)")
                }
                if l.hasPrefix(icyMetaDataHeader) {
                    let raw = l.replacingOccurrences(of: icyMetaDataHeader, with: "")
                    if let interval = Int(raw) {
                        _icyMetaDataInterval = interval
                    } else { _icyMetaDataInterval = 0 }
                }
                if l.hasPrefix(icyNameHeader) {
                    _icyName = l.replacingOccurrences(of: icyNameHeader, with: "")
                }
            }
            _icyHeadersParsed = true
            offset += 1
            delegate?.streamIsReadyRead()
        }

        func readICY() {
            let config = StreamConfiguration.shared

            if _icyReadBuffer == nil {
                _icyReadBuffer = Array(repeating: 0, count: Int(config.httpConnectionBufferSize))
            }
            print("Reading ICY stream for playback")
            var i = 0
            while offset < bufSize {
                let buf = buffers.advanced(by: offset).pointee
                // is this a metadata byte?
                if _metaDataBytesRemaining > 0 {
                    _metaDataBytesRemaining -= 1
                    if _metaDataBytesRemaining == 0 {
                        _dataByteReadCount = 0
                        if _icyMetaData.count > 0 {
                            guard let metaData = createMetaData(from: &_icyMetaData, numBytes: _icyMetaData.count) else {
                                // Metadata encoding failed, cannot parse.
                                offset += 1
                                _icyMetaData.removeAll()
                                continue
                            }
                            var metadataMap: [StreamConfiguration.MetaDataKey: StreamConfiguration.Metadata] = [:]
                            let tokens = metaData.components(separatedBy: ";")
                            for token in tokens {
                                if let range = token.range(of: "='") {
                                    let keyRange = Range(uncheckedBounds: (token.startIndex, range.lowerBound))
                                    let key = String(token[keyRange])
                                    let distance = token.distance(from: token.startIndex, to: keyRange.upperBound)
                                    let valueStart = token.index(token.startIndex, offsetBy: distance)
                                    let valueRange = Range(uncheckedBounds: (valueStart, token.endIndex))
                                    let value = String(token[valueRange])
                                    if let k = StreamConfiguration.MetaDataKey(rawValue: key) {
                                        metadataMap[k] = .text(value)
                                    } else {
                                        metadataMap[.other] = .other(key, value)
                                    }
                                }
                            }
                            if let name = _icyName { metadataMap[.title] = .text(name) }
                            delegate?.streamMetaDataAvailable(metaData: metadataMap)
//                            metadataHandler(metadataMap)
                        } // _icyMetaData.count > 0
                        _icyMetaData.removeAll()
                        offset += 1
                        continue
                    } // _metaDataBytesRemaining == 0
                    _icyMetaData.append(buf)
                    offset += 1
                    continue
                } // _metaDataBytesRemaining > 0

                // is this the interval byte?
                if _icyMetaDataInterval > 0 && _dataByteReadCount == _icyMetaDataInterval {
                    _metaDataBytesRemaining = Int(buf) * 16

                    if _metaDataBytesRemaining == 0 {
                        _dataByteReadCount = 0
                    }
                    offset += 1
                    continue
                }
                // a data byte
                i += 1
                _dataByteReadCount += 1
                let count = _icyReadBuffer?.count ?? 0
                if i < count {
                    _icyReadBuffer?[i] = buf
                }
                offset += 1
            }
            if var buffer = _icyReadBuffer, i > 0 {
                delegate?.streamHasBytesAvailable(data: &buffer, numBytes: UInt32(i))
            }
        }

        if _icyHeadersRead == false { readICYHeader() }
        else if _icyHeadersParsed == false { parseICYHeader() }
        readICY()
    }

    func createMetaData(from bytes: UnsafeMutablePointer<UInt8>, numBytes: Int) -> String? {
        let builtIns: [CFStringBuiltInEncodings] = [.UTF8, .isoLatin1, .windowsLatin1, .nextStepLatin]
        let encodings: [CFStringEncodings] = [.isoLatin2, .isoLatin3, .isoLatin4, .isoLatinCyrillic, .isoLatinGreek, .isoLatinHebrew, .isoLatin5, .isoLatin6, .isoLatinThai, .isoLatin7, .isoLatin8, .isoLatin9, .windowsLatin2, .windowsCyrillic, .windowsArabic, .KOI8_R, .big5]
        var total = builtIns.flatMap { $0.rawValue }
        total += encodings.flatMap { CFStringEncoding($0.rawValue) }
        total += [CFStringBuiltInEncodings.ASCII.rawValue]
        for enc in total {
            guard let meta = CFStringCreateWithBytes(kCFAllocatorDefault, bytes, numBytes, enc, false) as String? else { continue }
            return meta
        }
        return nil
    }
}

extension StreamProvider {

    enum Keys: String {
        case get = "GET"
        case userAgent = "User-Agent"
        case range = "Range"
        case icyMetadata = "Icy-MetaData"
        case icyMetaDataValue = "1"
        case icyMetaint = "icy-metaint"
        case icyName = "icy-name"
        case icyBr = "icy-br"
        case icySr = "icy-sr"
        case icyGenre = "icy-genre"
        case icyNotice1 = "icy-notice1"
        case icyNotice2 = "icy-notice2"
        case icyUrl = "icy-url"
        case icecastStationName = "IcecastStationName"
        case contentType = "Content-Type"
        case contentLength = "Content-Length"
        var cf: CFString { return rawValue as CFString }
    }

    public enum State { case none, ready, hasBytesAvailable, error(String), eof }
    /// URLInfo
    ///
    /// - remote: Http(s)
    /// - local: file
    /// - unknown: unknown
    public enum URLInfo {
        case remote(URL, AudioFileTypeID)
        case local(URL, AudioFileTypeID)
        case unknown(URL)

        public var isRemote: Bool { if case .remote = self { return true } else { return false } }

        public var url: URL {
            switch self {
            case let .remote(url, _): return url
            case let .local(url, _): return url
            case let .unknown(url): return url
            }
        }
        
        public var fileHint: AudioFileTypeID? {
            switch self {
            case let .remote(_, hint): return hint
            case let .local(_, hint): return hint
            case .unknown: return nil
            }
        }
        public var isWave: Bool {
            switch self {
            case let .remote(_, hint): return hint == kAudioFileWAVEType
            case let .local(_, hint): return hint == kAudioFileWAVEType
            default: return false
            }
        }

        public static func from(url: URL) -> URLInfo {
            guard let scheme = url.scheme?.lowercased() else { return .unknown(url) }
            if scheme == "file" {
                return .local(url, fileHint(from: url.pathExtension))
            } else if "https".contains(scheme) {
                return .remote(url, fileHint(from: url.pathExtension))
            }
            return .unknown(url)
        }

        /// Get fileHint from fileformat, file extension or content type,
        ///
        /// - Parameter value: fileformat, file extension or content type
        /// - Returns: AudioFileTypeID, default value is `kAudioFileMP3Type`
        public static func fileHint(from value: String) -> AudioFileTypeID {
            switch value.lowercased() {
            case "mp3", "mpg3", "audio/mpeg", "audio/mp3": return kAudioFileMP3Type
            case "wav", "wave", "audio/x-wav": return kAudioFileWAVEType
            case "aifc", "audio/x-aifc": return kAudioFileAIFCType
            case "aiff", "audio/x-aiff": return kAudioFileAIFFType
            case "m4a", "audio/x-m4a": return kAudioFileM4AType
            case "mp4", "mp4f", "mpg4", "audio/mp4", "video/mp4": return kAudioFileMPEG4Type
            case "caf", "caff", "audio/x-caf": return kAudioFileCAFType
            case "aac", "adts", "aacp", "audio/aac", "audio/aacp": return kAudioFileAAC_ADTSType
            default:return kAudioFileMP3Type
            }
        }
    }
}
