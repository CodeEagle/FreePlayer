//
//  AudioStream.swift
//  FreePlayer
//
//  Created by Lincoln Law on 2017/2/19.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//
import AudioToolbox
import CommonCrypto
// MARK: - AudioStreamDelegate
/// AudioStreamDelegate
protocol AudioStreamDelegate: class {
    func audioStreamStateChanged(state: AudioStreamState)
    func audioStreamErrorOccurred(errorCode: AudioStreamError , errorDescription: String )
    func audioStreamMetaDataAvailable(metaData: [String : Metadata])
    func samplesAvailable(samples: UnsafeMutablePointer<AudioBufferList>, frames: UInt32, description: AudioStreamPacketDescription)
    func bitrateAvailable()
}

// MARK: - AudioStream
/// AudioStream
final class AudioStream {
    
    private static let kAudioStreamBitrateBufferSize = 50
    
    weak var delegate: AudioStreamDelegate?
    
    var contentType = ""
    #if !os(OSX)
        var networkPermisionHandler: FPNetworkUsingPermisionHandler?
        var networkPermisionHandlerExecuteResponse: (() -> ())?
    #endif
    
    
    private var _inputStreamRunning = false
    private var _audioStreamParserRunning = false
    private var _initialBufferingCompleted = false
    private var _discontinuity = false
    private var _preloading = false
    private var _audioQueueConsumedPackets = false
    
    private var _outputVolume = Float(1)
    private var _volumeBeforeSeek = Float(1)
    private var _animating = false
    private lazy var _increaseDisplayLink: FreeDisplayLink = {
        let link = FreeDisplayLink(update: {[weak self] in
            self?.volumeUp()
        })
        link.stop()
        return link
    }()
    
    private var _urlUsingNetwork: URL?
    
    private var _packetIdentifier = UInt64()
    private var _playingPacketIdentifier = UInt64()
    private var _dataOffset = UInt64()
    private var _seekOffset = Float()
    private var _bounceCount = Int()
    private var _firstBufferingTime = CFAbsoluteTime()
    
    private var _strictContentTypeChecking = false
    private var _defaultContentType = "audio/mpeg"
    
    private var _defaultContentLength = UInt64()
    private var _contentLength = UInt64()
    private var _originalContentLength = UInt64()
    private var _bytesReceived = UInt64()
    
    private var _streamOpenPosition = Position()
    private var _currentPlaybackPosition = PlaybackPosition() /* record where it has played to */
    
    private var _inputStream: StreamInputProtocol?
    private var _audioQueue: AudioQueue?
    private var _state = AudioStreamState.stopped
    
    private var _fileOutput: StreamOutputManager?
    private var _fileOutputURL: URL?
    
    private weak var _queuedHead: QueuedPacket?
    private weak var _queuedTail: QueuedPacket?
    private weak var _playPacket: QueuedPacket?
    private var _packetSets: Set<QueuedPacket> = []
    private var _processedPackets: [UnsafeMutableRawPointer?] = []
    private var _packetsList: UnsafeMutablePointer<AudioStreamPacketDescription>?
    
    private var _watchdogTimer: CFRunLoopTimer?
    private var _seekTimer: CFRunLoopTimer?
    private var _inputStreamTimer: CFRunLoopTimer?
    private var _stateSetTimer: CFRunLoopTimer?
    
    private var _numPacketsToRewind = UInt()
    private var _cachedDataSize = Int()
    
    private var _audioDataByteCount = UInt64()
    private var _audioDataPacketCount = UInt64()
    private var _bitRate = UInt32()
    private var _metaDataSizeInBytes = UInt32()
    
    private var _packetDuration = Double()
    private var _bitrateBuffer: [Double] = Array(repeating: 0, count: kAudioStreamBitrateBufferSize)
    private var _bitrateBufferIndex = 0
    
    private var _decodeRunLoop: CFRunLoop?
    private var _mainRunLoop: CFRunLoop?
    private var _decodeQueue: DispatchQueue?
    private var _decodeTimer: DispatchSourceTimer?
    
    private var _audioFileStream: AudioFileStreamID?	// the audio file stream parser
    private var _audioConverter: AudioConverterRef?
    private var _srcFormat: AudioStreamBasicDescription?
    private var _dstFormat: AudioStreamBasicDescription
    private var _initializationError: OSStatus = noErr
    
    private var _outputBufferSize = UInt32()
    private var _outputBuffer: [UInt8] = []
    
    private var _converterRunOutOfData = false
    private var _decoderShouldRun = false
    private var _decoderShouldRunSetCount = 0
    private var _decoderFailed = false
    private var _decoderActive = false
    
    #if !os(OSX)
        private var _requireNetworkPermision = false
    #endif
    
    private var _decodeThread: pthread_t?
    
    private var _streamStateLock: OSSpinLock = OS_SPINLOCK_INIT
    private var _packetQueueLock: OSSpinLock = OS_SPINLOCK_INIT
    var forceStop = false
    private var _cleaning = false
    
    deinit {
        assert(Thread.isMainThread)
        clean()
    }
    
    init() {
        let config = StreamConfiguration.shared
        _strictContentTypeChecking = config.requireStrictContentTypeChecking
        #if !os(OSX)
            _requireNetworkPermision = config.requireNetworkPermision
        #endif
        
        _outputBufferSize = UInt32(config.bufferSize)
        _outputBuffer = Array(repeating: 0, count: Int(_outputBufferSize))
        _mainRunLoop = CFRunLoopGetCurrent()
        
        _dstFormat = AudioStreamBasicDescription()
        _dstFormat.mSampleRate = config.outputSampleRate
        _dstFormat.mFormatID = kAudioFormatLinearPCM
        _dstFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
        _dstFormat.mBytesPerPacket = 4
        _dstFormat.mFramesPerPacket = 1
        _dstFormat.mBytesPerFrame = 4
        _dstFormat.mChannelsPerFrame = 2
        _dstFormat.mBitsPerChannel = 16
        runDecodeloop()
    }
    
    func clean() {
        _cleaning = true
        _decodeTimer?.cancel()
        _decodeTimer = nil
        _increaseDisplayLink.invalidate()
        _streamStateLock.lock()
        _decoderShouldRun = false
        if let dl = _decodeRunLoop {
            CFRunLoopStop(dl)
            _decodeRunLoop = nil
        }
        _streamStateLock.unlock()
        _outputBuffer.removeAll()
        _inputStream = nil
        _fileOutput = nil
        close(withParser: true)
    }
}
// MARK: Volume Fade in and out
extension AudioStream {
    
    private func fadeout() {
        if _animating {
            volume = 0
            return
        }
        _animating = true
        _volumeBeforeSeek = volume
        _outputVolume = 0
        _increaseDisplayLink.isPaused = true
    }
    
    private func fadein() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {[weak self] in
            self?._increaseDisplayLink.isPaused = false
        }
    }
    
    @objc private func volumeUp() {
        if volume >= _volumeBeforeSeek {
            _increaseDisplayLink.isPaused = true
            _animating = false
        } else { volume += 0.1 }
    }
}

// MARK: Decode Loop
extension AudioStream {
    
    private func runDecodeloop() {
        let queue = DispatchQueue(label: "com.selfstudio.freeplayer.decodequeue", attributes: [])
        let timer = DispatchSource.makeTimerSource(flags: DispatchSource.TimerFlags(rawValue: 0), queue: queue)
        let pageStepTime: DispatchTimeInterval = .milliseconds(15)
        timer.schedule(deadline: .now() + pageStepTime, repeating: pageStepTime)
        timer.setEventHandler(handler: {[weak self] in
            guard let sself = self, sself._cleaning == false else { return }
            sself.decodeloopHandler()
        })
        timer.resume()
        _decodeQueue = queue
        _decodeTimer = timer
    }
    
    private func decodeloopHandler() {
        checkRunOutOfData()
        guard checkCanRun() else { return }
        converterFillComplexBuffer()
    }
    
    private func checkRunOutOfData() {
        _streamStateLock.lock()
        _decoderActive = true
        if _decoderShouldRun && _converterRunOutOfData {
            _streamStateLock.unlock()
            // Check if we got more data so we can run the decoder again
            _packetQueueLock.lock()
            if _playPacket != nil {
                // Yes, got data again
                _packetQueueLock.unlock()
                as_log("Converter run out of data: more data available. Restarting the audio converter")
                _streamStateLock.lock()
                if let convertor = _audioConverter { AudioConverterDispose(convertor) }
                if var src = _srcFormat {
                    let err = AudioConverterNew(&src, &_dstFormat, &_audioConverter)
                    if err != noErr {
                        as_log("Error in creating an audio converter, error \(err)")
                        _decoderFailed = true
                    }
                    _converterRunOutOfData = false
                    _streamStateLock.unlock()
                }
            } else {
                as_log("decoder: converter run out data: bailing out")
                _packetQueueLock.unlock()
                
            }
        } else { _streamStateLock.unlock() }
    }
    
    private func checkCanRun() -> Bool {
        if !decoderShouldRun {
            _streamStateLock.lock()
            _decoderActive = false
            _streamStateLock.unlock()
            return false
        }
        return true
    }
    
    private func converterFillComplexBuffer() {
        var outOutData = AudioBufferList()
        outOutData.mNumberBuffers = 1
        
        let listItem = AudioBuffer(mNumberChannels: _dstFormat.mChannelsPerFrame, mDataByteSize: _outputBufferSize, mData: &_outputBuffer)
        var outputBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: listItem)
        var ioOutputDataPackets = _outputBufferSize / _dstFormat.mBytesPerPacket
        
//        as_log("calling AudioConverterFillComplexBuffer")
        _packetQueueLock.lock()
        if _numPacketsToRewind > 0 {
            as_log("Rewinding \(_numPacketsToRewind) packets")
            var front = _playPacket
            _numPacketsToRewind -= 1
            while front != nil && _numPacketsToRewind > 0 {
                let tmp = front?.next
                front = tmp
                _numPacketsToRewind -= 1
            }
            _playPacket = front
            
            _numPacketsToRewind = 0
        }
        _packetQueueLock.unlock()
        
        let encoderDataCallback: AudioConverterComplexInputDataProc = { inAudioConverter, ioNumberDataPackets, ioBufferList, outDataPacketDescription, inUserData in
            guard let data = inUserData else { return noErr }
            let audioStream = data.to(object: AudioStream.self)
            return audioStream.encoderDataCallback(inAudioConverter: inAudioConverter,
                                                   ioNumberDataPackets: ioNumberDataPackets,
                                                   ioBufferList: ioBufferList,
                                                   outDataPacketDescription: outDataPacketDescription,
                                                   inUserData: inUserData)
        }
        
        guard let converter = _audioConverter else { return }
        let data = UnsafeMutableRawPointer.voidPointer(from: self)
        let err = AudioConverterFillComplexBuffer(converter,
                                                  encoderDataCallback,
                                                  data,
                                                  &ioOutputDataPackets,
                                                  &outputBufferList,
                                                  nil)
        checkError(err, dealingWith: outputBufferList)
    }
    
    private func checkError(_ err: OSStatus, dealingWith output: AudioBufferList) {
        var outputBufferList = output
        var description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: _outputBufferSize)
        _streamStateLock.lock()
        err.check(operation: "AudioConverterFillComplexBuffer")
        if err == noErr && _decoderShouldRun {
            _audioQueueConsumedPackets = true
            
            if _state != .playing && _stateSetTimer == nil {
                let data = UnsafeMutableRawPointer.voidPointer(from: self)
                // Set the playing state in the main thread
                var ctx = CFRunLoopTimerContext(version: 0, info: data, retain: nil, release: nil, copyDescription: nil)
                
                let callback: CFRunLoopTimerCallBack = { timer, userData in
                    guard let data = userData else { return }
                    let audioStream = data.to(object: AudioStream.self)
                    audioStream._streamStateLock.lock()
                    audioStream._stateSetTimer = nil
                    audioStream._streamStateLock.unlock()
                    audioStream.state = .playing
                }
                let timer = CFRunLoopTimerCreate(nil, 0, 0, 0, 0, callback, &ctx)
                _stateSetTimer = timer
                if let main = _mainRunLoop {
                    CFRunLoopAddTimer(main, timer, CFRunLoopMode.commonModes)
                }
            }
            _streamStateLock.unlock()
            
            // This blocks until the queue has been able to consume the packets
            let bytes = outputBufferList.mBuffers.mNumberChannels
            let packets = outputBufferList.mNumberBuffers
            if let inInputData = outputBufferList.mBuffers.mData {
                audioQueue.handleAudioPackets(inNumberBytes: bytes, inNumberPackets: packets, inInputData: inInputData, inPacketDescriptions: &description)
            }
            let size = outputBufferList.mBuffers.mDataByteSize
            let frame = _dstFormat.mBytesPerFrame
            let nFrames = size / frame
            delegate?.samplesAvailable(samples: &outputBufferList, frames: nFrames, description: description)
            
            let config = StreamConfiguration.shared
            _packetQueueLock.lock()
            /* The only reason we keep the already converted packets in memory
             * is seeking from the cache. If in-memory seeking is disabled we
             * can just cleanup the cache immediately. The same applies for
             * continuous streams. They are never seeked backwards.
             */
            if !config.seekingFromCacheEnabled || isContinuouStream ||
                _cachedDataSize >= config.maxPrebufferedByteCount {
                _packetQueueLock.unlock()
                cleanupCachedData()
            } else {
                _packetQueueLock.unlock()
            }
            
        } else if err == kAudio_ParamError {
            as_log("decoder: converter param error")
            /*
             * This means that iOS terminated background audio. Stream must be restarted.
             * Signal an error so that the app can handle it.
             */
            _decoderFailed = true
            _streamStateLock.unlock()
        } else {
            _streamStateLock.unlock()
        }
        if !decoderShouldRun {
            _streamStateLock.lock()
            _decoderActive = false
            _streamStateLock.unlock()
        }
    }
}

// MARK: Properties Utils
extension AudioStream {
    
    private var decoderShouldRun: Bool {
        let cstate = state
        
        _streamStateLock.lock()
        let noRuning = _preloading || !_decoderShouldRun || _converterRunOutOfData || _decoderFailed || cstate == .paused || cstate == .stopped || cstate == .seeking || cstate == .failed || cstate == .playbackCompleted || _dstFormat.mBytesPerPacket == 0
        if noRuning {
            _streamStateLock.unlock()
            return false
        } else {
            _streamStateLock.unlock()
            return true
        }
    }
    
    private var audioQueue: AudioQueue {
        if _audioQueue == nil {
            as_log("No audio queue, creating")
            _audioQueue = AudioQueue()
            _audioQueue?.delegate = self
            _audioQueue?.streamDesc = _dstFormat
            _audioQueue?.initialOutputVolume = _outputVolume
        }
        return _audioQueue!
    }
    
    private func closeAudioQueue() {
        if _audioQueue == nil { return }
        as_log("Releasing audio queue")
        _streamStateLock.lock()
        _audioQueueConsumedPackets = false
        _streamStateLock.unlock()
        _audioQueue?.stop(immediately: true)
        _audioQueue = nil
    }
    
    var volume: Float {
        get { return _outputVolume }
        set {
            var final = newValue
            if final > 1 { final = 1 }
            if final < 0 { final = 0 }
            _outputVolume = final
            _audioQueue?.volume = final
        }
    }
    
    var contentLength: UInt64 {
        _streamStateLock.lock()
        if _contentLength == 0 {
            if let input = _inputStream {
                _contentLength = UInt64(input.contentLength)
                if _contentLength == 0 {
                    _contentLength = _defaultContentLength
                }
            }
        }
        _streamStateLock.unlock()
        return _contentLength
    }
    
    var bytesReceived: Float {
        var dataSize = Float()
        OSSpinLockLock(&_packetQueueLock)
        dataSize = Float(_bytesReceived)
        OSSpinLockUnlock(&_packetQueueLock)
        return dataSize
    }
    
    var cachedDataSize: Int {
        var dataSize = 0
        _packetQueueLock.lock()
        dataSize = _cachedDataSize
        _packetQueueLock.unlock()
        return dataSize
    }
    
    var cachedDataCount: Int {
        as_log("lock: cachedDataCount")
        _packetQueueLock.lock()
        var count = 0
        var cur = _queuedHead
        while cur != nil {
            cur = cur?.next
            count += 1
        }
        as_log("unlock: cachedDataCount")
        _packetQueueLock.unlock()
        return count
    }
    
    var playbackDataCount: Int {
//        as_log("lock: playbackDataCount")
        _packetQueueLock.lock()
        var count = 0
        var cur = _playPacket
        while cur != nil {
            cur = cur?.next
            count += 1
        }
//        as_log("unlock: playbackDataCount")
        _packetQueueLock.unlock()
        return count
    }
    
    var bitrate: Float {
        // Use the stream provided bit rate, if available
        if _bitRate > 0 { return Float(_bitRate) }
        let total = AudioStream.kAudioStreamBitrateBufferSize
        // Stream didn't provide a bit rate, so let's calculate it
        if _bitrateBufferIndex < total - 1 { return 0 }
        var sum = Double()
        for i in 0..<AudioStream.kAudioStreamBitrateBufferSize {
            sum += _bitrateBuffer[i]
        }
        return floor(Float(sum) / Float(total))
    }
    
}
// MARK: Tools Utils
private extension AudioStream {
    
    func setCookies(for stream: AudioFileStreamID) {
        var err = noErr
        // get the cookie size
        var cookieSize = UInt32()
        var writable: DarwinBoolean = false
        
        err = AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable)
        if err != noErr { return }
        // get the cookie data
        let size = Int(cookieSize)
        let cookieData = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        err = AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, cookieData)
        if err != noErr {
            cookieData.deallocate(capacity: size)
            return
        }
        // set the cookie on the queue.
        if let value = _audioConverter {
            AudioConverterSetProperty(value, kAudioConverterDecompressionMagicCookie, cookieSize, cookieData)
        }
        cookieData.deallocate(capacity: size)
    }
    
    func closeAndSignalError(code: AudioStreamError, errorDescription: String) {
        as_log("error \(code), \(errorDescription)")
        state = .failed
        close(withParser: true)
        delegate?.audioStreamErrorOccurred(errorCode: code, errorDescription: errorDescription)
    }
    
    func cleanupCachedData() {
        _streamStateLock.lock()
        if _decoderShouldRun == false {
            as_log("decoder should not run, bailing out!")
            _streamStateLock.unlock()
            return
        } else {
            _streamStateLock.unlock()
        }
        _packetQueueLock.lock()
        
        if _processedPackets.count == 0 {
            _packetQueueLock.unlock()
            // Nothing can be cleaned yet, sorry
            as_log("Cache cleanup called but no free packets")
            return
        }
        guard let last = _processedPackets.last, let raw = last, _cleaning == false else {
            _packetQueueLock.unlock()
            return
        }
        let lastPacket = raw.to(object: QueuedPacket.self)
        
        var cur = _queuedHead
        var keepCleaning = true
        while cur != nil && keepCleaning {
            if cur?.identifier == lastPacket.identifier {
                as_log("Found lastPackect:\(lastPacket.identifier)")
                keepCleaning = false
            }
            let tmp = cur?.next
            _cachedDataSize -= Int(cur?.desc.mDataByteSize ?? 0)
            cur = nil
            cur = tmp
            _ = _processedPackets.popLast()
            _packetSets.remove(lastPacket)
            if cur == _playPacket {
                as_log("Found _playPacket:\(_playPacket?.identifier ?? 0)")
                break
            }
        }
        _queuedHead = cur
        _processedPackets.removeAll()
        _packetQueueLock.unlock()
    }
    
    // MARK: Watchdog Timer
    func createWatchdogTimer() {
        let config = StreamConfiguration.shared
        let duration = config.startupWatchdogPeriod
        if duration <= 0 { return }
        invalidateWatchdogTimer()
        /*
         * Start the WD if we have one requested. In this way we can track
         * that the stream doesn't stuck forever on the buffering state
         * (for instance some network error condition)
         */
        let userData = UnsafeMutableRawPointer.voidPointer(from: self)
        let callback: CFRunLoopTimerCallBack = { timer, userData in
            guard let data = userData else { return }
            let audioStream = data.to(object: AudioStream.self)
            audioStream._streamStateLock.lock()
            if !audioStream._audioQueueConsumedPackets {
                audioStream._streamStateLock.unlock()
                let config = StreamConfiguration.shared
                let errorDescription = "The stream startup watchdog activated: stream didn't start to play in \(config.startupWatchdogPeriod) seconds"
                audioStream.closeAndSignalError(code: .open, errorDescription: errorDescription)
            } else {
                audioStream._streamStateLock.unlock()
            }
        }
        var ctx = CFRunLoopTimerContext(version: 0, info: userData, retain: nil, release: nil, copyDescription: nil)
        let timer = CFRunLoopTimerCreate(nil, CFAbsoluteTimeGetCurrent() + CFAbsoluteTime(duration), 0, 0, 0, callback, &ctx)
        as_log("Starting the startup watchdog, period \(duration) seconds")
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, CFRunLoopMode.commonModes)
        _watchdogTimer = timer
    }
    
    func invalidateWatchdogTimer() {
        guard let timer = _watchdogTimer else { return }
        CFRunLoopTimerInvalidate(timer)
        _watchdogTimer = nil
        as_log("Watchdog invalidated")
    }
    
    func determineBufferingLimits() {
        let currentState = state
        if currentState == .paused || currentState == .seeking { return }
        
        let config = StreamConfiguration.shared
        
        if _initialBufferingCompleted { return }
        // Check if we have enough prebuffered data to start playback
        as_log("initial buffering not completed, checking if enough data")
        
        if config.usePrebufferSizeCalculationInPackets {
            let packetCount = cachedDataCount
            
            if packetCount >= config.requiredInitialPrebufferedPacketCount {
                as_log("More than \(packetCount) packets prebuffered, required \(config.requiredInitialPrebufferedPacketCount) packets. Playback can be started")
                _initialBufferingCompleted = true
                _streamStateLock.lock()
                _decoderShouldRun = true
                _streamStateLock.unlock()
                return
            }
        }
        
        var lim = 0
        if isContinuouStream {
            // Continuous stream
            lim = config.requiredInitialPrebufferedByteCountForContinuousStream
            as_log("continuous stream, \(lim) bytes must be cached to start the playback")
        } else {
            // Non-continuous
            lim = config.requiredInitialPrebufferedByteCountForNonContinuousStream
            as_log("non-continuous stream, \(lim) bytes must be cached to start the playback")
        }
        _packetQueueLock.lock()
        if _cachedDataSize > lim {
            _packetQueueLock.unlock()
            as_log("buffered \(_cachedDataSize) bytes, required for playback \(lim), starting playback")
            _initialBufferingCompleted = true
            _streamStateLock.lock()
            _decoderShouldRun = true
            _streamStateLock.unlock()
            
        } else {
            _packetQueueLock.unlock()
            as_log("not enough cached data to start playback")
        }
        
        // If the stream has never started playing and we have received 90% of the data of the stream,
        // let's override the limits
        var audioQueueConsumedPackets = false
        _streamStateLock.lock()
        audioQueueConsumedPackets = _audioQueueConsumedPackets
        _streamStateLock.unlock()
        let length = contentLength
        if !audioQueueConsumedPackets && length > 0 {
            let config = StreamConfiguration.shared
            let seekLength = Float(length) * _seekOffset
            as_log("seek length \(seekLength)")
            let numBytesRequiredToBeBuffered = (Float(length) - seekLength) * 0.9
            let byteRecieve = Float(_bytesReceived)
            as_log("audio queue not consumed packets, content length \(length), required bytes to be buffered \(numBytesRequiredToBeBuffered), byteRecieve:\(byteRecieve)")
            
            if byteRecieve >= numBytesRequiredToBeBuffered ||
                byteRecieve >= Float(config.maxPrebufferedByteCount) * 0.9 {
                _initialBufferingCompleted = true
                _streamStateLock.lock()
                _decoderShouldRun = true
                _streamStateLock.unlock()
                as_log("\(_bytesReceived) bytes received, overriding buffering limits")
            }
        }
        
    }
}
// MARK: - Static Utils
extension AudioStream {
    static func createIdentifier(for url: URL) -> String { return url.path.sha256() + ".dou" }
}
// MARK:  Public
extension AudioStream {
    
    func open() {
        let openZero = _currentPlaybackPosition.offset <= 0 || _currentPlaybackPosition.timePlayed <= 0 || isContinuouStream
        if openZero { open(position: Position()) }
        else {/* if playback position exsit, open by that position */
            var position = Position()
            let length = contentLength
            position.start = UInt64(floor(_currentPlaybackPosition.offset * Float(length)))
            position.end = length
            as_log("reopen start offset:\(_currentPlaybackPosition.offset).")
            as_log("reopen contentLength:\(length).")
            open(position: position)
            let delta = position.end - _dataOffset
            guard delta > 0 else { return }
            let top = Float(position.start - _dataOffset)
            var byteOffset = top / Float(delta)
            if byteOffset <= 0 { byteOffset = 0 }
            else if byteOffset >= 1 { byteOffset = 1 }
            _seekOffset =  byteOffset/* do not forget to set offset */
        }
    }
    
    private func open(position: Position) {
        if _inputStreamRunning || _audioStreamParserRunning {
            as_log("already running: return")
            return
        }
        _contentLength = 0
        _bytesReceived = 0
        _seekOffset = 0
        _bounceCount = 0
        _firstBufferingTime = 0
        _bitrateBufferIndex = 0
        _initializationError = noErr
        _converterRunOutOfData = false
        _audioDataPacketCount = 0
        _bitRate = 0
        _metaDataSizeInBytes = 0
        _discontinuity = true
        
        _streamStateLock.lock()
        _audioQueueConsumedPackets = false
        _decoderShouldRun = false
        _decoderFailed    = false
        _streamStateLock.unlock()
        
        _packetQueueLock.lock()
        _numPacketsToRewind = 0
        _packetQueueLock.unlock()
        
        invalidateWatchdogTimer()
        
        let config = StreamConfiguration.shared
        
        var success = false
        
        if position.start != 0 && position.end != 0  {
            _initialBufferingCompleted = false
            if let stream = _inputStream { success = stream.open(position) }
        } else {
            _initialBufferingCompleted = false
            _packetIdentifier = 0
            if let stream = _inputStream { success = stream.open() }
        }
        
        if success {
            as_log("stream opened, buffering...")
            _inputStreamRunning = true
            state = .buffering
            _streamStateLock.lock()
            
            if !_preloading && config.startupWatchdogPeriod > 0 {
                _streamStateLock.unlock()
                createWatchdogTimer()
            } else {
                _streamStateLock.unlock()
            }
        } else {
            var type: AudioStreamError = .open
            #if !os(OSX)
                if _requireNetworkPermision == true && _urlUsingNetwork != nil {
                    type = .networkPermission
                }
            #endif
            _inputStreamRunning = false
            _audioStreamParserRunning = false
            closeAndSignalError(code: type, errorDescription: "Input stream open error")
        }
    }
    
    func close(withParser closeParser: Bool = false) {
        
        as_log("enter")
        invalidateWatchdogTimer()
        
        if let timer = _seekTimer {
            CFRunLoopTimerInvalidate(timer)
            _seekTimer = nil
        }
        
        if let timer = _inputStreamTimer {
            CFRunLoopTimerInvalidate(timer)
            _inputStreamTimer = nil
        }
        
        _streamStateLock.lock()
        if let timer = _stateSetTimer {
            CFRunLoopTimerInvalidate(timer)
            _stateSetTimer = nil
        }
        _streamStateLock.unlock()
        
        /* Close the HTTP stream first so that the audio stream parser
         isn't fed with more data to parse */
        if _inputStreamRunning {
            _inputStream?.close()
            _inputStreamRunning = false
        }
        
        if closeParser && _audioStreamParserRunning {
            if let stream = _audioFileStream {
                AudioFileStreamClose(stream).check(operation: "AudioFileStreamClose failed")
                _audioFileStream = nil
            }
            _audioStreamParserRunning = false
        }
        
        _streamStateLock.lock()
        _decoderShouldRun = false
        _streamStateLock.unlock()
        
        _packetQueueLock.lock()
        _playPacket = nil
        as_log("_playPacket: nil")
        _packetQueueLock.unlock()
        
        closeAudioQueue()
        
        let currentState = state
        
        if .failed != currentState && .seeking != currentState {
            /*
             * Set the stream state to stopped if the stream was stopped successfully.
             * We don't want to cause a spurious stopped state as the fail state should
             * be the final state in case the stream failed.
             */
            state = .stopped
        }
        if let converter = _audioConverter { AudioConverterDispose(converter) }
        /*
         * Free any remaining queud packets for encoding.
         */
        _packetQueueLock.lock()
        
        _processedPackets.removeAll()
        autoreleasepool {
            _packetSets.removeAll()
        }
        _cachedDataSize = 0
        _numPacketsToRewind = 0
        _packetQueueLock.unlock()
        as_log("leave")
    }
    
    func pause() { audioQueue.pause() }
    
    func resume() { audioQueue.resume() }
    
    func rewind(in seconds: UInt) {
        if isContinuouStream == false { return }
        let packetCount = cachedDataCount
        if packetCount == 0 { return }
        
        let averagePacketSize = Float64(cachedDataSize) / Float64(packetCount)
        let bufferSizeForSecond = Float64(bitrate / 8)
        let totalAudioRequiredInBytes = Float64(seconds) * bufferSizeForSecond
        
        let packetsToRewind = totalAudioRequiredInBytes / averagePacketSize
        
        if Float64(packetCount) - packetsToRewind >= 16 {
            // Leave some safety margin so that the stream doesn't immediately start buffering
            _packetQueueLock.lock()
            _numPacketsToRewind = UInt(packetsToRewind)
            _packetQueueLock.unlock()
        }
    }
    
    func startCachedDataPlayback() {
        _streamStateLock.lock()
        _preloading = false
        _streamStateLock.unlock()
        if !_inputStreamRunning {
            // Already reached EOF, restart
            open()
        } else {
            determineBufferingLimits()
        }
    }
    
    func setStrictContentType(checking: Bool) { _strictContentTypeChecking = checking }
    
    func setDefaultContent(type: String) { _defaultContentType = type }
    
    func setSeek(to offset: Float) { _seekOffset = offset }
    
    var defaultContentLength: UInt64 { return _defaultContentLength }
    func setDefaultContent(length: UInt64) {
        _streamStateLock.lock()
        _defaultContentLength = length
        _streamStateLock.unlock()
    }
    
    func setPreloading(loading: Bool) {
        _streamStateLock.lock()
        _preloading = loading
        _streamStateLock.unlock()
    }
    
    var isPreloading: Bool {
        _streamStateLock.lock()
        let value = _preloading
        _streamStateLock.unlock()
        return value
    }
    
    var isContinuouStream: Bool { return contentLength <= 0 }
    
    func setOuput(file: URL?) {
        guard let url = file else {
            _fileOutput = nil
            _fileOutputURL = nil
            return
        }
        _fileOutput = StreamOutputManager(fileURL: url)
        _fileOutputURL = url
    }
    
    func outputFileURL() -> URL? { return _fileOutputURL }
    
    var state: AudioStreamState {
        get {
            _streamStateLock.lock()
            let value = _state
            _streamStateLock.unlock()
            return value
        }
        set(val) {
            _streamStateLock.lock()
            if (_state == val) {
                _streamStateLock.unlock()
                return
            }
            _state = val
            _streamStateLock.unlock()
            delegate?.audioStreamStateChanged(state: val)
        }
    }
    
    var sourceFormatDescription: String {
        guard let format = _srcFormat else { return "" }
        let mFormatID = format.mFormatID
        var description: String = ""
        let byte1 = mFormatID & 0xff
        let byte2 = (mFormatID & 0xff00) >> 8
        let byte3 = (mFormatID & 0xff0000) >> 16
        let byte4 = (mFormatID & 0xff000000) >> 24
        // add the highest byte first
        description += String(format:"%c",byte4)
        description += String(format:"%c",byte3)
        description += String(format:"%c",byte2)
        description += String(format:"%c",byte1)
        return "formatID: \(description), sample rate: \(format.mSampleRate)"
    }
}

// MARK: AudioQueue Utils
extension AudioStream {
    var playBackPosition: PlaybackPosition {
        var position = PlaybackPosition()
        if _audioStreamParserRunning {
            let queueTime = audioQueue.currentTime
            let durationInSeconds = ceil(duration)
            position.timePlayed = (durationInSeconds * _seekOffset) +
                Float(queueTime.mSampleTime / _dstFormat.mSampleRate)
            if durationInSeconds > 0 {
                position.offset = position.timePlayed / durationInSeconds
            }
        }
        return position
    }
    
    var duration: Float {
        let framesPerPacket = _srcFormat?.mFramesPerPacket ?? 0
        let rate = _srcFormat?.mSampleRate ?? 0
        if _audioDataPacketCount > 0 && framesPerPacket > 0 {
            return floor(Float(_audioDataPacketCount) * Float(framesPerPacket) / Float(rate))
        }
        // Not enough data provided by the format, use bit rate based estimation
        var audioFileLength = UInt64()
        
        if _audioDataByteCount > 0 {
            audioFileLength = _audioDataByteCount
        } else {
            audioFileLength = contentLength - UInt64(_metaDataSizeInBytes)
        }
        
        if audioFileLength > 0 {
            // 总播放时间 = 文件大小 * 8 / 比特率
            let rate = ceil(bitrate / 1000) * 1000 * 0.125
            if rate > 0 {
                let length = Float(audioFileLength)
                let dur = floor(length / rate)
                return dur
            }
        }
        return 0
    }
    
    func seek(to offset: Float) {
        let currentState = state
        
        if (!(currentState == .playing || currentState == .endOfFile)) {
            // Do not allow seeking if we are not currently playing the stream
            // This allows a previous seek to be completed
            return
        }
        state = .seeking
        
        _originalContentLength = contentLength
        
        _streamStateLock.lock()
        _decoderShouldRun = false
        _streamStateLock.unlock()
        
        _packetQueueLock.lock()
        _numPacketsToRewind = 0
        _packetQueueLock.unlock()
        
        _inputStream?.setScheduledInRunLoop(run: false)
        
        _seekOffset = offset
        
        if let timer = _seekTimer { CFRunLoopTimerInvalidate(timer) }
        let userData = UnsafeMutableRawPointer.voidPointer(from: self)
        var ctx = CFRunLoopTimerContext(version: 0, info: userData, retain: nil, release: nil, copyDescription: nil)
        let callback: CFRunLoopTimerCallBack = { timer, userData in
            guard let data = userData else { return }
            let audioStream = data.to(object: AudioStream.self)
            DispatchQueue.main.async {
                audioStream.seekTimerCallback()
            }
        }
        let timer = CFRunLoopTimerCreate(nil, CFAbsoluteTimeGetCurrent(), 0.050, 0, 0, callback, &ctx)
        _seekTimer = timer
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, CFRunLoopMode.commonModes)
    }
    
    func streamPosition(for offset: Float) -> Position {
        var position = Position()
        let durationInSeconds = duration
        if durationInSeconds <= 0 { return position }
        let seekByteOffset = Float(_dataOffset) + offset * Float(contentLength - _dataOffset)
        position.start = UInt64(seekByteOffset)
        position.end = contentLength
        return position
    }
    
    func set(playRate: Float) { _audioQueue?.setPlayRate(playRate: playRate) }
    
    func set(url u: URL?) {
        as_log("url:\(u?.absoluteString ?? "")")
        guard let url = u else { return }
        _urlUsingNetwork = nil
        _inputStream?.close()
        _inputStream = nil
        if HttpStream.canHandle(url: url) {
            let config = StreamConfiguration.shared
            if nil != config.storeDirectory {
                as_log("has config.storeDirectory")
                let cache = CachingStream(target: HttpStream())
                let id = AudioStream.createIdentifier(for: url)
                let result = cache.setStoreIdentifier(id: id)
                as_log("config.cacheEnabled:\(config.cacheEnabled)")
                as_log("cache.setStoreIdentifier:\(result)")
                if config.cacheEnabled, result == false {
                    cache.setCacheIdentifier(id: id)
                    as_log("cache.setCacheIdentifier")
                    if !cache.cachedComplete {
                        as_log("cachedComplete: false")
                        _urlUsingNetwork = url
                    }
                }
                _inputStream = cache
            } else {
                as_log("not has config.storeDirectory")
                if config.cacheEnabled {
                    let cache = CachingStream(target: HttpStream())
                    let id = AudioStream.createIdentifier(for: url)
                    cache.setCacheIdentifier(id: id)
                    if !cache.cachedComplete {
                        _urlUsingNetwork = url
                    }
                    _inputStream = cache
                } else {
                     as_log("config.cacheEnabled is false")
                    _inputStream = HttpStream()
                    _urlUsingNetwork = url
                }
            }
        } else if FileStream.canHandle(url: url) {
            _inputStream = FileStream()
        }
        _inputStream?.delegate = self
        #if os(OSX)
            _inputStream?.set(url: url)
        #else
            as_log("_requireNetworkPermision:\(_requireNetworkPermision), _urlUsingNetwork:\(_urlUsingNetwork?.absoluteString ?? "")")
            if !_requireNetworkPermision || _urlUsingNetwork == nil {
                _inputStream?.set(url: url)
            } else {
                if networkPermisionHandler == nil {
                    as_log("networkPermisionHandler can not be nil when _requireNetworkPermision is true")
                    assert(false)
                }
                networkPermisionHandler?({[weak self] canPlay in
                    guard canPlay else { return }
                    self?._inputStream?.set(url: url)
                    self?.networkPermisionHandlerExecuteResponse?()
                })
            }
        #endif
    }
    
    
    
    
    static func audioStreamType(from contentType: String?) -> AudioFileTypeID {
        var fileTypeHint = kAudioFileMP3Type
        guard let type = contentType else {
            as_log("***** Unable to detect the audio stream type: missing content-type! *****")
            return fileTypeHint
        }
        switch type {
        case "audio/mpeg", "audio/mp3": fileTypeHint = kAudioFileMP3Type
        case "audio/x-wav": fileTypeHint = kAudioFileWAVEType
        case "audio/x-aifc": fileTypeHint = kAudioFileAIFCType
        case "audio/x-aiff": fileTypeHint = kAudioFileAIFFType
        case "audio/x-m4a": fileTypeHint = kAudioFileM4AType
        case "audio/mp4", "video/mp4": fileTypeHint = kAudioFileMPEG4Type
        case "audio/x-caf": fileTypeHint = kAudioFileCAFType
        case "audio/aac", "audio/aacp": fileTypeHint = kAudioFileAAC_ADTSType
        default:as_log("***** Unable to detect the audio stream type *****")
        }
        as_log("\(fileTypeHint) detected")
        return fileTypeHint
    }
}

// MARK: - StreamInputDelegate
extension AudioStream: StreamInputDelegate {
    func streamIsReadyRead() {
        if _audioStreamParserRunning {
            as_log("parser already running!")
            return
        }
        let prefix = ["audio/", "application/octet-stream"]
        var matchesAudioContentType = false
        if let _contentType = _inputStream?.contentType  {
            contentType = _contentType
            for pre in prefix {
                if contentType.hasPrefix(pre) {
                    matchesAudioContentType = true
                    break
                }
            }
        }
        
        if !matchesAudioContentType && _strictContentTypeChecking {
            var msg = "Strict content type checking active, no content type provided by the server"
            if !contentType.isEmpty {
                msg = "Strict content type checking active, \(contentType) is not an audio content type"
            }
            closeAndSignalError(code: .open, errorDescription: msg)
            return
        }
        _audioDataByteCount = 0
        let this = UnsafeMutableRawPointer.voidPointer(from: self)
        let id = contentType.isEmpty ? _defaultContentType : contentType
        let fileHint = AudioStream.audioStreamType(from: id)
        let propertyCallback: AudioFileStream_PropertyListenerProc = {  userData, inAudioFileStream, propertyId, ioFlags in
            let sself = userData.to(object: AudioStream.self)
            sself.propertyValueCallback(userData: userData,
                                        inAudioFileStream: inAudioFileStream,
                                        propertyId: propertyId,
                                        ioFlags: ioFlags)
        }
        let callback: AudioFileStream_PacketsProc = { userData, inNumberBytes, inNumberPackets, inInputData, inPacketDescriptions in
            let sself = userData.to(object: AudioStream.self)
            sself.streamDataCallback(inNumberBytes: inNumberBytes, inNumberPackets: inNumberPackets, inInputData: inInputData, inPacketDescriptions: inPacketDescriptions)
        }
        let result = AudioFileStreamOpen(this, propertyCallback, callback, fileHint, &_audioFileStream)
        if result == noErr {
            as_log("audio file stream opened.")
            _audioStreamParserRunning = true
        } else {
            let msg = "Audio file stream parser open error"
            closeAndSignalError(code: .open, errorDescription: msg)
            result.check(operation: "Audio file stream parser open error")
        }
    }
    
    func streamHasBytesAvailable(data: UnsafePointer<UInt8>, numBytes: UInt32) {
        if !_inputStreamRunning {
            as_log("stray callback detected!")
            return
        }
//        log_pointer(data: data, len: numBytes)
        _packetQueueLock.lock()
        
        let config = StreamConfiguration.shared
        
        if _cachedDataSize >= config.maxPrebufferedByteCount {
            _packetQueueLock.unlock()
            
            // If we got a cache overflow, disable the input stream so that we don't get more data
            _inputStream?.setScheduledInRunLoop(run: false)
            
            // Schedule a timer to watch when we can enable the input stream again
            if let timer = _inputStreamTimer {
                CFRunLoopTimerInvalidate(timer)
                _inputStreamTimer = nil
            }
            let this = UnsafeMutableRawPointer.voidPointer(from: self)
            var ctx = CFRunLoopTimerContext(version: 0, info: this, retain: nil, release: nil, copyDescription: nil)
            let callback: CFRunLoopTimerCallBack = { timer, userData in
                guard let data = userData else { return }
                let audioStream = data.to(object: AudioStream.self)
                if !audioStream._inputStreamRunning {
                    if let timer = audioStream._inputStreamTimer {
                        CFRunLoopTimerInvalidate(timer)
                    }
                    return
                }
                audioStream._packetQueueLock.lock()
                let config = StreamConfiguration.shared
                if audioStream._cachedDataSize < config.maxPrebufferedByteCount {
                    audioStream._packetQueueLock.unlock()
                    audioStream._inputStream?.setScheduledInRunLoop(run: true)
                } else {
                    audioStream._packetQueueLock.unlock()
                }
            }
            let timer = CFRunLoopTimerCreate(nil, CFAbsoluteTimeGetCurrent(), 0.1, 0, 0, callback, &ctx)
            _inputStreamTimer = timer
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, CFRunLoopMode.commonModes)
        } else {
            _packetQueueLock.unlock()
        }
        
        var decoderFailed = false
        _streamStateLock.lock()
        decoderFailed = _decoderFailed
        _streamStateLock.unlock()
        if decoderFailed {
            closeAndSignalError(code: .terminated, errorDescription: "Stream terminated abrubtly")
            return
        }
        
        _bytesReceived += UInt64(numBytes)
        _fileOutput?.write(data: data, length: Int(numBytes))
        
        guard _audioStreamParserRunning , let stream = _audioFileStream else { return }
        let result = AudioFileStreamParseBytes(stream, numBytes, data, _discontinuity ? AudioFileStreamParseFlags.discontinuity : AudioFileStreamParseFlags.init(rawValue: 0))
        if result != noErr {
            result.check(operation: "AudioFileStreamParseBytes error")
            var type: AudioStreamError = .streamParse
            var msg = "Audio file stream parse bytes error"
            if result == kAudioFileStreamError_NotOptimized {
                type = .unsupportedFormat
                msg = "Non-optimized formats not supported for streaming"
            }
            closeAndSignalError(code: type, errorDescription: msg)
        } else if _initializationError == kAudioConverterErr_FormatNotSupported {
            closeAndSignalError(code: .unsupportedFormat, errorDescription: sourceFormatDescription)
        } else if _initializationError != noErr {
            _initializationError.check(operation: "Error in audio stream initialization")
            closeAndSignalError(code: .open, errorDescription: "Error in audio stream initialization")
        } else {
            _discontinuity = false
        }
    }
    
    func streamEndEncountered() {
        as_log("enter")
        if !_inputStreamRunning {
            as_log("stray callback detected!")
            return
        }
        if isContinuouStream {
            /* Continuous streams are not supposed to end */
            closeAndSignalError(code: .network, errorDescription: "Stream ended abruptly")
            return
        }
        state = .endOfFile
        _inputStream?.close()
        _inputStreamRunning = false
    }
    
    func streamErrorOccurred(errorDesc: String) {
        as_log("enter")
        if !_inputStreamRunning {
            as_log("stray callback detected!")
            return
        }
        if errorDesc.hasPrefix(HttpStream.fixedCodeError) {
            let raw = errorDesc.replacingOccurrences(of: HttpStream.fixedCodeError, with: "")
            if let errorCode = Int(raw), errorCode == 404 {
                closeAndSignalError(code: .badURL, errorDescription: errorDesc)
                return
            }
        }
        closeAndSignalError(code: .network, errorDescription: errorDesc)
    }
    
    func streamMetaDataAvailable(metaData: [String: Metadata]) {
        delegate?.audioStreamMetaDataAvailable(metaData: metaData)
    }
    
    func streamMetaDataByteSizeAvailable(sizeInBytes: UInt32) {
        _metaDataSizeInBytes = sizeInBytes
        as_log("metadata size received \(sizeInBytes)")
    }
    
    func streamHasDataCanPlay() -> Bool {
        return _state == .playing || _state == .paused
    }
}

// MARK: - AudioQueueDelegate
extension AudioStream: AudioQueueDelegate {
    func audioQueueStateChanged(state: AudioQueue.State) {
        if (state == .running) {
            invalidateWatchdogTimer()
            self.state = .playing
            if let c = _audioQueue?.volume, c != _outputVolume {
                _audioQueue?.volume = _outputVolume
            }
        }
        else if state == .idle { self.state = .stopped }
        else if state == .paused { self.state = .paused }
    }
    
    func audioQueueBuffersEmpty() {
        as_log("enter")
        /*
         * Entering here means that the audio queue has run out of data to play.
         */
        let count = playbackDataCount
        /*
         * If we don't have any cached data to play and we are still supposed to
         * feed the audio queue with data, enter the buffering state.
         */
        if count == 0 && _inputStreamRunning && state != .failed {
            let config = StreamConfiguration.shared
            
            _packetQueueLock.lock()
            _playPacket = _queuedHead
            
            if _processedPackets.count > 0 {
                /*
                 * We have audio packets in memory (only case with a non-continuous stream),
                 * so figure out the correct location to set the playback pointer so that we don't
                 * start decoding the packets from the beginning when
                 * buffering resumes.
                 */
                if let first = _processedPackets.first, let raw = first {
                    let firstPacket = raw.to(object: QueuedPacket.self)
                    var cur = _queuedHead
                    while cur != nil {
                        if cur?.identifier == firstPacket.identifier {
                            break
                        }
                        cur = cur?.next
                    }
                    if cur != nil {
                        _playPacket = cur
                        
                    }
                }
            }
            
            _packetQueueLock.unlock()
            // Always make sure we are scheduled to receive data if we start buffering
            _inputStream?.setScheduledInRunLoop(run: true)
            
            as_log("⚠️Audio queue run out data, starting buffering⚠️")
            // check if inputStream has error
            if let stream = _inputStream, let inputStreamError = stream.errorDescription {
                _inputStream?.close()
                streamErrorOccurred(errorDesc: inputStreamError)
                return
            }
            
            state = .buffering
            
            if _firstBufferingTime == 0 {
                // Never buffered, just increase the counter
                _firstBufferingTime = CFAbsoluteTimeGetCurrent()
                _bounceCount += 1
                as_log("stream buffered, increasing bounce count \(_bounceCount), interval \(config.bounceInterval)")
            } else {
                // Buffered before, calculate the difference
                let cur = CFAbsoluteTimeGetCurrent()
                
                let diff = cur - _firstBufferingTime
                
                if Int(diff) >= config.bounceInterval {
                    // More than bounceInterval seconds passed from the last
                    // buffering. So not a continuous bouncing. Reset the
                    // counters.
                    _bounceCount = 0
                    _firstBufferingTime = 0
                    
                    as_log("\(diff) seconds passed from last buffering, resetting counters, interval \(config.bounceInterval)")
                } else {
                    _bounceCount += 1
                    as_log("\(diff) seconds passed from last buffering, increasing bounce count to \(_bounceCount), interval \(config.bounceInterval)")
                }
            }
            
            // Check if we have reached the bounce state
            if _bounceCount >= config.maxBounceCount {
                closeAndSignalError(code: .streamBouncing, errorDescription: "Buffered \(_bounceCount) times in the last \(config.maxBounceCount) seconds")
            }
            // Create the watchdog in case the input stream gets stuck
            createWatchdogTimer()
            return
        }
        as_log("\(count) cached packets, enqueuing")
        // Keep enqueuing the packets in the queue until we have them
        _packetQueueLock.lock()
        if _playPacket != nil && count > 0 {
            _packetQueueLock.unlock()
            determineBufferingLimits()
        } else {
            _packetQueueLock.unlock()
            as_log("closing the audio queue")
            FPLogger.shared.save()
            if forceStop { return }
            let totalDuration = duration
            let total = playBackPosition.timePlayed
            let delta = totalDuration - total
            if delta >= 1, delta < 2 {
                as_log("finish after:\(delta)")
                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + DispatchTimeInterval.milliseconds(Int(ceil(delta * 1000)))) {[weak self] in
                    self?.state = .playbackCompleted
                }
            } else if delta < 1 {
                state = .playbackCompleted
            } else {
                as_log("closeAndSignalError: not playing end of file")
                closeAndSignalError(code: .network, errorDescription: "not playing end of file")
            }
        }
    }
    
    func audioQueueInitializationFailed() {
        if _inputStreamRunning {
            _inputStream?.close()
            _inputStreamRunning = false
        }
        state = .failed
        var code = AudioStreamError.streamParse
        var msg = "Audio queue failed"
        if audioQueue.lastError == kAudioFormatUnsupportedDataFormatError {
            code = .unsupportedFormat
            msg += "unsupported format"
        }
        delegate?.audioStreamErrorOccurred(errorCode: code, errorDescription: msg)
    }
    func audioQueueFinishedPlayingPacket() {
        _currentPlaybackPosition = playBackPosition
    }
}


// MARK:  Call Backs
private extension AudioStream {
    
    // MARK: encoderDataCallback
    func encoderDataCallback(inAudioConverter: AudioConverterRef, ioNumberDataPackets: UnsafeMutablePointer<UInt32>, ioBufferList: UnsafeMutablePointer<AudioBufferList>, outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?, inUserData: UnsafeMutableRawPointer?) -> OSStatus {
        
        
//        as_log("encoderDataCallback 1: lock")
        _packetQueueLock.lock()
        // Dequeue one packet per time for the decoder
        let f = _playPacket
        guard let front = f else {
            /* Don't deadlock */
            as_log("Run Out Of Data")
            _packetQueueLock.unlock()
            /*
             * End of stream - Inside your input procedure, you must set the total amount of packets read and the sizes of the data in the AudioBufferList to zero. The input procedure should also return noErr. This will signal the AudioConverter that you are out of data. More specifically, set ioNumberDataPackets and ioBufferList->mDataByteSize to zero in your input proc and return noErr. Where ioNumberDataPackets is the amount of data converted and ioBufferList->mDataByteSize is the size of the amount of data converted in each AudioBuffer within your input procedure callback. Your input procedure may be called a few more times; you should just keep returning zero and noErr.
             */
            _streamStateLock.lock()
            _converterRunOutOfData = true
            _streamStateLock.unlock()
            ioNumberDataPackets.pointee = 0
            ioBufferList.pointee.mBuffers.mDataByteSize = 0
            return noErr
        }
        ioNumberDataPackets.pointee = 1
        
        if let d = front.data {
            let bytes = UnsafeMutablePointer<UInt8>(mutating: d)
            let buffer = UnsafeMutableRawPointer(bytes)
            // put the data pointer into the buffer list
            let ioDataPtr = UnsafeMutableAudioBufferListPointer(ioBufferList)
            ioDataPtr[0].mData = buffer
            ioDataPtr[0].mDataByteSize = front.desc.mDataByteSize
            ioDataPtr[0].mNumberChannels = _srcFormat?.mChannelsPerFrame ?? 2
        }
        
        _packetsList?.deallocate(capacity: 1)
        let desc = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        desc.initialize(to: front.desc)
        outDataPacketDescription?.pointee = desc
        _packetsList = desc
        
        let next = front.next
        if next == nil {
            let target = front.identifier + 1
            let available = _packetSets.filter({ (packst) -> Bool in
                return packst.identifier == target
            })
            if let here = available.first {
                front.next = here
            }
        }
        _playPacket = front.next
        
        let raw = Unmanaged<QueuedPacket>.passUnretained(front).toOpaque()
        _processedPackets.insert(raw, at: 0)
//        as_log("encoderDataCallback 5: unlock")
        _packetQueueLock.unlock()
        return noErr
    }
    
    // MARK: seekTimerCallback
    private func seekTimerCallback() {
        
        guard let rate = _srcFormat?.mSampleRate, rate > 0, state == .seeking else { return }
        
        _streamStateLock.lock()
        
        if _decoderActive {
            as_log("decoder still active, postponing seeking!")
            _streamStateLock.unlock()
            return
        } else {
            as_log("decoder free, seeking")
            if let timer = _seekTimer { CFRunLoopTimerInvalidate(timer) }
            _streamStateLock.unlock()
        }
        // Close the audio queue so that it won't ask any more data
        closeAudioQueue()
        var position = streamPosition(for: _seekOffset)
        if position.start == 0 && position.end == 0 {
            closeAndSignalError(code: .network, errorDescription: "Failed to retrieve seeking position")
            return
        }
        let duration = self.duration
        let packet = _srcFormat?.mFramesPerPacket ?? 0
        
        let packetDuration = Double(packet) / Double(rate)
        if packetDuration > 0 {
            var ioFlags = AudioFileStreamSeekFlags.offsetIsEstimated
            var packetAlignedByteOffset = Int64()
            let seekPacket = Int64(floor((duration * _seekOffset) / Float(packetDuration)))
            _playingPacketIdentifier = UInt64(seekPacket)
            if let stream = _audioFileStream {
                let err = AudioFileStreamSeek(stream, seekPacket, &packetAlignedByteOffset, &ioFlags)
                if err == noErr {
                    position.start = UInt64(packetAlignedByteOffset) + _dataOffset
                } else {
                    closeAndSignalError(code: .network, errorDescription: "Failed to calculate seeking position")
                    return
                }
            }
        } else {
            closeAndSignalError(code: .network, errorDescription: "Failed to calculate seeking position")
            return
        }
        let config = StreamConfiguration.shared
        
        // Do a cache lookup if we can find the seeked packet from the cache and no need to
        // open the stream from the new position
        var foundCachedPacket = false
        var seekPacket: QueuedPacket? = nil
        
        if config.seekingFromCacheEnabled {
            as_log("lock: seekToOffset")
            _packetQueueLock.lock()
            var cur = _queuedHead
            while cur != nil {
                if cur?.identifier == _playingPacketIdentifier {
                    foundCachedPacket = true
                    seekPacket = cur
                    break
                }
                let tmp = cur?.next
                cur = tmp
            }
            as_log("unlock: seekToOffset")
            _packetQueueLock.unlock()
        } else { as_log("Seeking from cache disabled") }
        if (!foundCachedPacket) {
            as_log("Seeked packet not found from cache, reopening the input stream")
            
            // Close but keep the stream parser running
            close()
            _bytesReceived = 0
            _bounceCount = 0
            _firstBufferingTime = 0
            _bitrateBufferIndex = 0
            _initializationError = noErr
            _converterRunOutOfData = false
            _discontinuity = true
            
            // check if inputStream has error
            guard let stream = _inputStream else { return }
            if let errString = stream.errorDescription {
                _inputStream?.close()
                closeAndSignalError(code: .network, errorDescription: errString)
                return
            }
            let success = stream.open(position)
            if success {
                _contentLength = _originalContentLength
                
                _streamStateLock.lock()
                
                if let c = _audioConverter { AudioConverterDispose(c) }
                guard var format = _srcFormat else { return }
                let err = AudioConverterNew(&format, &_dstFormat, &_audioConverter)
                if err != noErr {
                    closeAndSignalError(code: .open, errorDescription: "Error in creating an audio converter")
                    _streamStateLock.unlock()
                    return
                }
                _streamStateLock.unlock()
                state = .buffering
                _inputStreamRunning = true
            } else {
                _inputStreamRunning = false
                _audioStreamParserRunning = false
                closeAndSignalError(code: .open, errorDescription: "Input stream open error")
                return
            }
        } else {
            as_log("Seeked packet found from cache!")
            // Found the packet from the cache, let's use the cache directly.
            _packetQueueLock.lock()
            _playPacket = seekPacket
            
            _packetQueueLock.unlock()
            _discontinuity = true
            state = .playing
        }
        fadeout()
        audioQueue.reset(isSeeking: true)
        fadein()
        _inputStream?.setScheduledInRunLoop(run: true)
        _streamStateLock.lock()
        _decoderShouldRun = true
        _streamStateLock.unlock()
    }
    
    // MARK: propertyValueCallback
    private func propertyValueCallback(userData: UnsafeMutableRawPointer, inAudioFileStream: AudioFileStreamID, propertyId: AudioFileStreamPropertyID, ioFlags: UnsafeMutablePointer<AudioFileStreamPropertyFlags>) {
        if !_audioStreamParserRunning {
            as_log("stray callback detected!")
            return
        }
        func bitRate() {
            let bitrate = _bitRate
            let sizeReceivedForFirstTime = bitrate == 0
            var bitRateSize = UInt32(MemoryLayout.size(ofValue: bitrate))
            let err = AudioFileStreamGetProperty(inAudioFileStream,
                                                 kAudioFileStreamProperty_BitRate,
                                                 &bitRateSize, &_bitRate)
            if err != noErr { _bitRate = 0 }
            else if sizeReceivedForFirstTime {
                delegate?.bitrateAvailable()
            }
        }
        func dataOffset() {
            var offset = UInt64()
            var offsetSize = UInt32(MemoryLayout<UInt64>.size)
            let result = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataOffset, &offsetSize, &offset)
            if result == noErr {
                _dataOffset = offset
            } else {
                as_log("reading kAudioFileStreamProperty_DataOffset property failed")
            }
        }
        func audioDataByteCount() {
            var byteCountSize = UInt32(MemoryLayout.size(ofValue: _audioDataByteCount))
            let err = AudioFileStreamGetProperty(inAudioFileStream,
                                                 kAudioFileStreamProperty_AudioDataByteCount,
                                                 &byteCountSize, &_audioDataByteCount)
            if err != noErr { _audioDataByteCount = 0 }
        }
        func audioDataPacketCount() {
            var packetCountSize = UInt32(MemoryLayout.size(ofValue: _audioDataPacketCount))
            let err = AudioFileStreamGetProperty(inAudioFileStream,
                                                 kAudioFileStreamProperty_AudioDataPacketCount,
                                                 &packetCountSize, &_audioDataPacketCount)
            if err != noErr { _audioDataPacketCount = 0 }
        }
        func readyToProducePackets() {
            let size = MemoryLayout<AudioStreamBasicDescription>.size
            _srcFormat = AudioStreamBasicDescription()
            var asbdSize = UInt32(size)
            var formatListSize = UInt32()
            var writable: DarwinBoolean = false
            var err = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &asbdSize, &_srcFormat)
            if err != noErr {
                as_log("Unable to set the src format")
                return
            }
            let result = AudioFileStreamGetPropertyInfo(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, &writable)
            if result == noErr {
                let total =  Int(formatListSize)
                let formatListData = UnsafeMutablePointer<AudioFormatListItem>.allocate(capacity: total)
                let error = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, formatListData)
                if error == noErr {
                    let size = MemoryLayout<AudioFormatListItem>.size
                    var i = 0
                    
                    while i < total {
                        let pasbd = formatListData.advanced(by: i).pointee
                        as_log("pasbd.mASBD.mFormatID:\(pasbd.mASBD.mFormatID)")
                        if pasbd.mASBD.mFormatID == kAudioFormatMPEG4AAC_HE ||
                            pasbd.mASBD.mFormatID == kAudioFormatMPEG4AAC_HE_V2 {
                            _srcFormat = pasbd.mASBD
                            break
                        }
                        i += size
                    }
                }
                formatListData.deallocate(capacity: total)
            }
            guard var src = _srcFormat else { return }
            _packetDuration = Double(src.mFramesPerPacket) / Double(src.mSampleRate)
            as_log("srcFormat, bytes per packet \(src.mBytesPerPacket)")
            
            if let c = _audioConverter { AudioConverterDispose(c) }
            
            err = AudioConverterNew(&src, &(_dstFormat), &(_audioConverter))
            if err != noErr {
                as_log("Error in creating an audio converter, error \(err)")
                _initializationError = err
            }
            setCookies(for: inAudioFileStream)
            audioQueue.reset()
        }
        
        switch propertyId {
        case kAudioFileStreamProperty_BitRate: bitRate()
        case kAudioFileStreamProperty_DataOffset: dataOffset()
        case kAudioFileStreamProperty_AudioDataByteCount: audioDataByteCount()
        case kAudioFileStreamProperty_AudioDataPacketCount: audioDataPacketCount()
        case kAudioFileStreamProperty_ReadyToProducePackets: readyToProducePackets()
        default:break
        }
    }
    
    // MARK: streamDataCallback
    private func streamDataCallback(inNumberBytes: UInt32, inNumberPackets: UInt32, inInputData: UnsafeRawPointer, inPacketDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>) {
        if !_audioStreamParserRunning {
            as_log("stray callback detected!")
            return
        }
//        as_log("inNumberBytes:\(inNumberBytes), inNumberPackets:\(inNumberPackets)")
        let inputData = Data(bytes: inInputData, count: Int(inNumberBytes))
        for index in 0..<inNumberPackets {
            autoreleasepool(invoking: {
                /* Allocate the packet */
                let i = Int(index)
                let size = inPacketDescriptions.advanced(by: i).pointee.mDataByteSize
                let packet = QueuedPacket()
                packet.identifier = _packetIdentifier
                
                // If the stream didn't provide bitRate (m_bitRate == 0), then let's calculate it
                if _bitRate == 0 && _bitrateBufferIndex < AudioStream.kAudioStreamBitrateBufferSize {
                    // Only keep sampling for one buffer cycle; this is to keep the counters (for instance) duration
                    // stable.
                    let index = _bitrateBufferIndex
                    _bitrateBuffer[index] = Double(8 * size) / _packetDuration
                    _bitrateBufferIndex += 1
                    if _bitrateBufferIndex == AudioStream.kAudioStreamBitrateBufferSize {
                        delegate?.bitrateAvailable()
                    }
                }
                
//                as_log("lock")
                _packetQueueLock.lock()
                
                /* Prepare the packet */
                packet.next = nil
                packet.desc = inPacketDescriptions.advanced(by: i).pointee
                packet.desc.mStartOffset = 0
                
                let offset = Int(inPacketDescriptions.advanced(by: i).pointee.mStartOffset)
                
                let index: Range<Data.Index> = Range(uncheckedBounds: (offset, offset + Int(size)))
                let sub = inputData.subdata(in: index)
                let subdata = sub.map{ $0 }
                packet.data = subdata.map{ $0 }
                // _queuedHead(0) -> _queuedTail(n)
                if _queuedHead == nil {
                    _queuedHead = packet
                    _queuedTail = packet
                    _playPacket = packet
                } else {
                    let currentID = _queuedTail?.identifier ?? 0
                    if packet.identifier == currentID + 1 {
                        _queuedTail?.next = packet
                        _queuedTail = packet
                    }
                }
                _packetSets.insert(packet)
                _cachedDataSize += Int(size)
                _packetIdentifier += 1
//                as_log("unlock")
                _packetQueueLock.unlock()
            })
        }
        determineBufferingLimits()
    }
}

// MARK: - Struct
extension AudioStream {
    private final class QueuedPacket: Hashable {
        var identifier = UInt64()
        var desc: AudioStreamPacketDescription! = AudioStreamPacketDescription()
        weak var next: QueuedPacket?
        var data: [UInt8]?
        
        init() { }
        
        static func ==(lhs: QueuedPacket, rhs: QueuedPacket) -> Bool {
            return lhs.identifier == rhs.identifier
        }
        
        var hashValue: Int { return Int(identifier) }
    }
}

extension String {
    func sha256() -> String {
        guard let messageData = data(using: .utf8) else { return self }
        var digestData = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = digestData.withUnsafeMutableBytes {digestBytes in
            messageData.withUnsafeBytes {messageBytes in
                CC_SHA256(messageBytes, CC_LONG(messageData.count), digestBytes)
            }
        }
        let shaHex = digestData.map { String(format: "%02x", $0) }.joined()
        return shaHex
    }
}
