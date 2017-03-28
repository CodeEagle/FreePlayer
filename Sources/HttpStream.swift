//
//  HttpStream.swift
//  FreePlayer
//
//  Created by Lincoln Law on 2017/2/21.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//

import AudioToolbox
import CFNetwork

/// HttpStream
final class HttpStream {
    // MARK: StreamInputProtocol
    weak var delegate: StreamInputDelegate?
    var position = Position()
    var contentType = ""
    var contentLength = UInt64()
    var errorDescription: String?
    
    fileprivate var _url: URL?
    fileprivate var _readStream: CFReadStream?
    fileprivate var _scheduledInRunLoop = false
    fileprivate var _readPending = false
    fileprivate var _openTimer: CFRunLoopTimer?
    fileprivate var _reopenTimes = 0
    fileprivate var _isReadedData = false
    fileprivate var _maxRetryCount = 10
    fileprivate var _id3Parser: ID3Parser?
    
    // MARK: HTTP headers
    fileprivate var _httpHeadersParsed = false
    fileprivate var _bytesRead = UInt64()
    
    // MARK: ICY protocol
    fileprivate var _icyStream = false
    fileprivate var _icyHeaderCR = false
    fileprivate var _icyHeadersRead = false
    fileprivate var _icyHeadersParsed = false
    fileprivate var _icyName: String?
    fileprivate var _icyHeaderLines: [String] = []
    fileprivate var _icyMetaDataInterval = 0
    fileprivate var _dataByteReadCount = 0
    fileprivate var _metaDataBytesRemaining = 0
    fileprivate var _icyMetaData: [UInt8] = []
    
    // MARK: Read buffers
    fileprivate var _icyReadBuffer:[UInt8]?
    fileprivate var _httpReadBuffer: [UInt8]?
    
    fileprivate var _auth: CFHTTPAuthentication?
    fileprivate var _credentials: [String : String]?
    
    deinit {
        close()
        _icyHeaderLines.removeAll()
        contentType = ""
        _icyName = ""
        _httpReadBuffer = nil
        _icyReadBuffer = nil
        _url = nil
        _id3Parser = nil
    }
    
    init() {
        _id3Parser = ID3Parser()
        _id3Parser?.delegate = self
    }
    
}
// MARK: Timer
fileprivate extension HttpStream {
    //start open timer
    func startOpenTimer(_ interval: CFTimeInterval) {
        if let timer = _openTimer { CFRunLoopTimerInvalidate(timer) }
        let this = UnsafeMutableRawPointer.voidPointer(from: self)
        var ctx = CFRunLoopTimerContext(version: 0, info: this, retain: nil, release: nil, copyDescription: nil)
        let timer = CFRunLoopTimerCreate(nil, CFAbsoluteTimeGetCurrent()+interval, interval, 0, 0, HttpStream.openTimerCallback, &ctx)
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, CFRunLoopMode.commonModes)
        _openTimer = timer
    }
    //invalidate timer
    func resetOpenTimer(needResetReadedFlag: Bool) {
        if let timer = _openTimer { CFRunLoopTimerInvalidate(timer) }
        _reopenTimes = 0 /* reset reopen count anyway */
        if (needResetReadedFlag) { _isReadedData = false }
    }
    //close stream if need invalidate timer
    func close(resetTimer: Bool) {
        guard let stream = _readStream else { return } /* The stream has been already closed */
        CFReadStreamSetClient(stream, 0, nil, nil)
        setScheduledInRunLoop(run: false)
        CFReadStreamClose(stream)
        _readStream = nil
        if (resetTimer) { resetOpenTimer(needResetReadedFlag: true) }
    }
    
    func handleStreamError() {
        /*if error occurred, stop timer, reset m_isReadedData */
        resetOpenTimer(needResetReadedFlag: true)
        if let stream = _readStream, let err = CFReadStreamCopyError(stream), let desc = CFErrorCopyDescription(err) {
            errorDescription = desc as String
        }
        if let de = delegate, let err = errorDescription {
            if de.streamHasDataCanPlay() == false { de.streamErrorOccurred(errorDesc: err) }
            else { startOpenTimer(2) }
        }
    }
}
// MARK: Utils
extension HttpStream {
    
    @discardableResult func createReadStream(from url: URL?) -> CFReadStream? {
        guard let u = url else { return nil }
        
        let config = StreamConfiguration.shared
        let request = CFHTTPMessageCreateRequest(kCFAllocatorDefault, Keys.get.cf, u as CFURL, kCFHTTPVersion1_1).takeUnretainedValue()
        if let ua = config.userAgent {
            CFHTTPMessageSetHeaderFieldValue(request, Keys.userAgent.cf, ua as CFString)
        }
        CFHTTPMessageSetHeaderFieldValue(request, Keys.icyMetadata.cf, Keys.icyMetaDataValue.cf)
        
        if position.start > 0 && position.end > position.start {
            let range = "bytes=\(position.start)-\(position.end)" as CFString
            CFHTTPMessageSetHeaderFieldValue(request, Keys.range.cf, range)
        }
        
        for (key, value) in config.predefinedHttpHeaderValues {
            hs_log("Setting predefined HTTP header[\(key) : \(value)]")
            CFHTTPMessageSetHeaderFieldValue(request, key as CFString, value as CFString)
        }
        
        if let authentication = _auth, let info = _credentials {
            let credentials = info as CFDictionary
            if CFHTTPMessageApplyCredentialDictionary(request, authentication, credentials, nil) == false {
                delegate?.streamErrorOccurred(errorDesc: "add authentication fail")
                return nil
            }
            hs_log("digest authentication add success")
        }
        let s = CFReadStreamCreateForHTTPRequest(kCFAllocatorDefault, request)
        let stream = s.takeRetainedValue()
        CFReadStreamSetProperty(stream, CFStreamPropertyKey(rawValue: kCFStreamNetworkServiceType), kCFStreamNetworkServiceTypeBackground)
        CFReadStreamSetProperty(stream, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPShouldAutoredirect), kCFBooleanTrue)
        if config.usingCustomProxy {
            var dict: [String : Any] = [:]
            dict[kCFNetworkProxiesHTTPPort as String] = config.customProxyHttpPort
            dict[kCFNetworkProxiesHTTPProxy as String] = config.customProxyHttpHost
            let proxy = dict as CFDictionary
            if false == CFReadStreamSetProperty(stream, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPProxy), proxy) {
                hs_log("setting custom proxy not success")
            }
        } else {
            if let proxy = CFNetworkCopySystemProxySettings()?.takeUnretainedValue() {
                let dict = proxy as NSDictionary
                hs_log("system proxy:\(dict)")
                CFReadStreamSetProperty(stream, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPProxy), proxy)
            }
        }
        return stream
    }
    
    func parseHttpHeadersIfNeeded(buffer: UnsafeMutablePointer<UInt8>, bufSize: Int) {
        if _httpHeadersParsed { return }
        guard let readStream = _readStream else { return }
        _httpHeadersParsed = true
        
        if bufSize >= 10 {
            var datas = [UInt8]()
            //HTTP/1.0 200 OK
            /* If the response has the "ICY 200 OK" string,
             * we are dealing with the ShoutCast protocol.
             * The HTTP headers won't be available.
             */
            var icy = ""
            for i in 0..<4 {
                let buf = buffer.advanced(by: i).pointee
                datas.append(buf)
            }
            var data = Data(bytes: datas)
            icy = String(data: data, encoding: .ascii) ?? ""
            for i in 4..<10 {
                let buf = buffer.advanced(by: i).pointee
                datas.append(buf)
            }
            data = Data(bytes: datas)
            icy = String(data: data, encoding: .ascii) ?? ""
            // This is an ICY stream, don't try to parse the HTTP headers
            if icy.lowercased() == "ICY 200 OK" { return }
        }
        
        hs_log("A regular HTTP stream")
        
        guard let resp = CFReadStreamCopyProperty(readStream, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPResponseHeader)) else { return }
        let response = resp as! CFHTTPMessage
        var statusCode = 0
        
        /*
         * If the server responded with the icy-metaint header, the response
         * body will be encoded in the ShoutCast protocol.
         */
        let icyMetaIntString = CFHTTPMessageCopyHeaderFieldValue(response, Keys.icyMetaint.cf)?.takeUnretainedValue()
        if let meta = icyMetaIntString {
            _icyStream = true
            _icyHeadersParsed = true
            _icyHeadersRead = true
            _icyMetaDataInterval = Int(CFStringGetIntValue(meta))
        }
        hs_log("\(Keys.icyMetaint.rawValue): \(_icyMetaDataInterval)")
        
        statusCode = CFHTTPMessageGetResponseStatusCode(response)
        hs_log("HTTP response code: \(statusCode)")
        
        let icyNameString = CFHTTPMessageCopyHeaderFieldValue(response, Keys.icyName.cf)?.takeUnretainedValue()
        if let name = icyNameString {
            let n = name as String
            _icyName = n
            delegate?.streamMetaDataAvailable(metaData: [Keys.icecastStationName.rawValue : Metadata.text(n)])
        }
        
        let ctype = CFHTTPMessageCopyHeaderFieldValue(response, Keys.contentType.cf)?.takeUnretainedValue()
        contentType = (ctype as String?) ?? ""
        hs_log("\(Keys.contentType.rawValue): \(contentType)")
        let status200 = statusCode == 200
        let serverError = 500...599
        let clen = CFHTTPMessageCopyHeaderFieldValue(response, Keys.contentLength.cf)?.takeUnretainedValue()
        if let len = clen, status200 {
            contentLength = UInt64(CFStringGetIntValue(len))
            hs_log("contentLength:\(contentLength)")
        }
        if status200 || statusCode == 206 {
            delegate?.streamIsReadyRead()
        } else {
            if [401, 407].contains(statusCode) {
                let responseHeader = CFReadStreamCopyProperty(readStream, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPResponseHeader)) as! CFHTTPMessage
                // Get the authentication information from the response.
                let authentication = CFHTTPAuthenticationCreateFromResponse(nil, responseHeader).takeUnretainedValue()
                // <CFHTTPAuthentication 0x1703e1100>{state = InProgress; scheme = Digest, forProxy = false}
                if CFHTTPAuthenticationRequiresUserNameAndPassword(authentication) {
                    let conf = StreamConfiguration.shared
                    var credentials: [String : String] = [:]
                    credentials[kCFHTTPAuthenticationUsername as String] = conf.customProxyUsername
                    credentials[kCFHTTPAuthenticationPassword as String] = conf.customProxyPassword
                    _credentials = credentials
                    _auth = authentication
                }
                hs_log("did recieve authentication challenge")
                resetOpenTimer(needResetReadedFlag: true)
                startOpenTimer(0.5)
            } else if serverError.contains(statusCode) {
                hs_log("server error:\(statusCode)")
                resetOpenTimer(needResetReadedFlag: true)
                startOpenTimer(0.5)
            } else {
                delegate?.streamErrorOccurred(errorDesc: "HTTP response code \(statusCode)")
            }
        }
    }
    
    func parseICYStream(buffers: UnsafeMutablePointer<UInt8>, bufSize: Int) {
        hs_log("Parsing an IceCast stream, received \(bufSize) bytes")
        var offset = 0
        var bytesFound = 0
        func readICYHeader() {
            hs_log("ICY headers not read, reading")
            while offset < bufSize {
                let buffer = buffers.advanced(by: offset).pointee
                let bufferString = String(Character(UnicodeScalar(buffer)))
                if bufferString == "", _icyHeaderCR {
                    if bytesFound > 0 {
                        var bytes: [UInt8] = []
                        let total = offset - bytesFound
                        for i in 0..<total {
                            bytes.append(buffers.advanced(by: i).pointee)
                        }
                        if let line = createMetaData(from: &bytes, numBytes: total) {
                            _icyHeaderLines.append(line)
                            hs_log("_icyHeaderLines:\(line)")
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
                    contentType = line.replacingOccurrences(of: icyContentTypeHeader, with: "")
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
            hs_log("Reading ICY stream for playback")
            var i = 0
            while offset < bufSize {
                let buf = buffers.advanced(by: offset).pointee
                // is this a metadata byte?
                if _metaDataBytesRemaining > 0 {
                    _metaDataBytesRemaining -= 1
                    if _metaDataBytesRemaining == 0 {
                        _dataByteReadCount = 0
                        if let dele = delegate, _icyMetaData.count > 0 {
                            guard let metaData = createMetaData(from: &_icyMetaData, numBytes: _icyMetaData.count) else {
                                // Metadata encoding failed, cannot parse.
                                offset += 1
                                _icyMetaData.removeAll()
                                continue
                            }
                            var metadataMap = [String : Metadata]()
                            let tokens = metaData.components(separatedBy: ";")
                            for token in tokens {
                                if let range = token.range(of: "='") {
                                    let keyRange = Range(uncheckedBounds: (token.startIndex, range.lowerBound))
                                    let key = token.substring(with: keyRange)
                                    let distance = token.distance(from: token.startIndex, to: keyRange.upperBound)
                                    let valueStart = token.index(token.startIndex, offsetBy: distance)
                                    let valueRange = Range(uncheckedBounds: (valueStart, token.endIndex))
                                    let value = token.substring(with: valueRange)
                                    metadataMap[key] = Metadata.text(value)
                                }
                            }
                            if let name = _icyName { metadataMap[Keys.icecastStationName.rawValue] = Metadata.text(name) }
                            dele.streamMetaDataAvailable(metaData: metadataMap)
                        }// _icyMetaData.count > 0
                        _icyMetaData.removeAll()
                        offset += 1
                        continue
                    }// _metaDataBytesRemaining == 0
                    _icyMetaData.append(buf)
                    offset += 1
                    continue
                }//_metaDataBytesRemaining > 0
                
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
        
        if !_icyHeadersRead { readICYHeader() }
        else if !_icyHeadersParsed { parseICYHeader() }
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

// MARK: static info
extension HttpStream {
    enum Keys: String {
        case get = "GET"
        case userAgent = "User-Agent"
        case range = "Range"
        case icyMetadata = "Icy-MetaData"
        case icyMetaDataValue = "1"
        case icyMetaint = "icy-metaint"
        case icyName = "icy-name"
        case icecastStationName = "IcecastStationName"
        case contentType = "Content-Type"
        case contentLength = "Content-Length"
        var cf: CFString { return rawValue as CFString }
    }
}
// MARK: CFReadStreamClientCallBack
extension HttpStream {
    
    static var openTimerCallback: CFRunLoopTimerCallBack {
        return { _, info in
            guard let userData = info else { return }
            let hs = userData.to(object: HttpStream.self)
            if hs.errorDescription != nil {
                hs.close(resetTimer: false)
                /* reopen from the error position */
                let start = hs.position.start + hs._bytesRead
                let end = hs.position.end
                if end >= start {
                    hs_log("reopen debug: try reopen from HTTP stream error.")
                    var errorPosition = Position()
                    errorPosition.start = hs.position.start + hs._bytesRead
                    errorPosition.end = end
                    hs.open(errorPosition)
                } else {
                    hs.open()
                }
            } else {
                if let timer = hs._openTimer { /* do not reopen reset count */
                    CFRunLoopTimerInvalidate(timer)
                }
                /* if did not received data, try to reopen stream */
                if hs._isReadedData == false {
                    hs_log("reopen debug: try reopen stream times \(hs._reopenTimes)")
                    hs.close(resetTimer: true)
                    if hs.position.end >= hs.position.start {
                        hs.open(hs.position)
                    } else {
                        hs.open()
                    }
                } else if hs._bytesRead < hs.contentLength, hs.contentLength > 0 {
                    var errorPosition = Position()
                    errorPosition.start = hs._bytesRead
                    errorPosition.end = hs.contentLength
                    hs.close(resetTimer: true)
                    hs.open(errorPosition)
                }
            }
        }
    }
    
    static var readCallBack: CFReadStreamClientCallBack {
        return { stream, eventType, info in
            guard let userData = info else { return }
            let hs = userData.to(object: HttpStream.self)
            let config = StreamConfiguration.shared
            
            func hasBytesAvailable(force: Bool = false) {
                hs.resetOpenTimer(needResetReadedFlag: true)
                hs._isReadedData = true
                hs.errorDescription = nil
                hs_log("reopen debug: HTTP stream did receive data")
                
                if hs._httpReadBuffer == nil {
                    hs._httpReadBuffer = Array(repeating: 0, count: Int(config.httpConnectionBufferSize))
                }
                guard var httpReadBuffer = hs._httpReadBuffer else {
                    hs_log("not in")
                    return
                }
                while CFReadStreamHasBytesAvailable(stream) {
                    /*
                     * This is critical - though the stream has data available,
                     * do not try to feed the audio queue with data, if it has
                     * indicated that it doesn't want more data due to buffers
                     * full.
                     */
                    if hs._scheduledInRunLoop == false {
                        hs._readPending = true
                        hs_log("_readPending")
                        break
                    }
                    let bytesRead = CFReadStreamRead(stream, &httpReadBuffer, CFIndex(config.httpConnectionBufferSize))
                    
                    if CFReadStreamGetStatus(stream) == CFStreamStatus.error || bytesRead < 0 {
                        if hs.contentLength > 0 {
                            /*
                             * Try to recover gracefully if we have a non-continuous stream
                             */
                            let currentPosition = hs.position
                            var recoveryPosition: Position = Position()
                            recoveryPosition.start = currentPosition.start + hs._bytesRead
                            recoveryPosition.end = hs.contentLength
                            hs_log("Recovering HTTP stream, start \(recoveryPosition.start)")
                            hs.resetOpenTimer(needResetReadedFlag: true)
                            hs.open(recoveryPosition)
                            break
                        }
                        hs.handleStreamError()
                        break
                    }
                    
                    if bytesRead > 0 {
                        hs._bytesRead += UInt64(bytesRead)
                        hs_log("Read \(bytesRead) bytes, total to read: \(hs.contentLength)")
                        hs.parseHttpHeadersIfNeeded(buffer: &httpReadBuffer, bufSize: bytesRead)
                        if hs._icyStream == false && hs._id3Parser?.wantData() == true {
                            hs._id3Parser?.feedData(data: &httpReadBuffer, numBytes: UInt32(bytesRead))
                        }
                        if hs._icyStream {
                            hs_log("Parsing ICY stream")
                            hs.parseICYStream(buffers: &httpReadBuffer, bufSize: bytesRead)
                        } else {
//                            hs_log("Not an ICY stream; calling the delegate back")
                            hs.delegate?.streamHasBytesAvailable(data: &httpReadBuffer, numBytes: UInt32(bytesRead))
                        }
                    }
                }
            }
            func endEncountered() {
                if let myResponse = CFReadStreamCopyProperty(stream, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPResponseHeader)) {
                    let code = CFHTTPMessageGetResponseStatusCode(myResponse as! CFHTTPMessage)
                    if code == 401 { return }
                }
                if hs._bytesRead < hs.contentLength {
                    hs_log("HTTP stream endEncountered when not all content[\(hs.contentLength)] stream, restart with postion \(hs._bytesRead)")
                    hs.startOpenTimer(0.5)
                } else {
                    hs.resetOpenTimer(needResetReadedFlag: true)
                    hs.delegate?.streamEndEncountered()
                }
            }
            switch eventType {
            case CFStreamEventType.hasBytesAvailable: hasBytesAvailable()
            case CFStreamEventType.endEncountered: endEncountered()
            case CFStreamEventType.errorOccurred:  hs.handleStreamError()
            default: break
            }
        }
    }
}

// MARK: - ID3ParserDelegate
extension HttpStream: ID3ParserDelegate {
    func id3metaDataAvailable(metaData: [String : Metadata]) {
        delegate?.streamMetaDataAvailable(metaData: metaData)
    }
    
    func id3tagSizeAvailable(tag size: UInt32) {
        delegate?.streamMetaDataByteSizeAvailable(sizeInBytes: size)
    }
}
// MARK: StreamInputProtocol
extension HttpStream: StreamInputProtocol {
    
    @discardableResult func open(_ position: Position) -> Bool {
        let this = UnsafeMutableRawPointer.voidPointer(from: self)
        var ctx = CFStreamClientContext(version: 0, info: this, retain: nil, release: nil, copyDescription: nil)
        if _readStream != nil {
            as_log("Already opened a read stream, return")
            return false
        }/* Already opened a read stream, return */
        /* Reset state */
        self.position = position
        _readPending = false
        _httpHeadersParsed = false
        contentType = ""
        
        _icyStream = false
        _icyHeaderCR = false
        _icyHeadersRead = false
        _icyHeadersParsed = false
        _icyName = ""
        _icyHeaderLines.removeAll()
        
        _icyMetaDataInterval = 0
        _dataByteReadCount = 0
        _metaDataBytesRemaining = 0
        _bytesRead = position.start
        
        guard let stream = createReadStream(from: _url) else {
            as_log("createReadStream fail")
            return false
        }
        _readStream = stream
        let flags = CFStreamEventType.hasBytesAvailable.rawValue | CFStreamEventType.endEncountered.rawValue | CFStreamEventType.errorOccurred.rawValue
        if CFReadStreamSetClient(stream, flags, HttpStream.readCallBack, &ctx) == false { return false }
        setScheduledInRunLoop(run: true)
        if CFReadStreamOpen(stream) == false {/* Open failed: clean */
            CFReadStreamSetClient(stream, 0, nil, nil)
            setScheduledInRunLoop(run: false)
            as_log("CFReadStreamOpen fail")
            return false
        }
        if _reopenTimes < _maxRetryCount { /* try reopen */
            _reopenTimes += 1
            _isReadedData = false
            startOpenTimer(3) // 3s to detect if need reopen stream
        }
        return true
    }
    
    @discardableResult func open() -> Bool {
        contentLength = 0
        _id3Parser?.reset()
        return open(Position())
    }
    
    func close() { close(resetTimer: true) }
    
    func setScheduledInRunLoop(run: Bool) {
        guard let stream = _readStream else { return }/* The stream has not been opened, or it has been already closed */
        /* The state doesn't change */
        if _scheduledInRunLoop == run { return }
        if _scheduledInRunLoop {
            CFReadStreamUnscheduleFromRunLoop(stream, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes)
        } else {
            if _readPending {
                _readPending = false
                let this = UnsafeMutableRawPointer.voidPointer(from: self)
                HttpStream.readCallBack(stream, CFStreamEventType.hasBytesAvailable, this)
            }
            CFReadStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes)
        }
        _scheduledInRunLoop = run
    }
    
    func set(url: URL) { _url = url }
}

// MARK: canHandleURL
extension HttpStream {
    static func canHandle(url: URL?) -> Bool {
        guard let u = url else { return false }
        return u.scheme != "file"
    }
}

