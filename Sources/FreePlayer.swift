//
//  FreePlayer.swift
//  FreePlayer
//
//  Created by Lincoln Law on 2017/2/28.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//

import AVFoundation
#if os(iOS)
    import UIKit
    import AudioToolbox
#endif

public final class FreePlayer {
    public var maxRetryCount = 3
    public var onStateChange: ((AudioStreamState) -> Void)?
    public var onComplete: (() -> Void)?
    public var onFailure: ((AudioStreamError, String?) -> Void)?
    #if !os(OSX)
        public var networkPermisionHandler: FPNetworkUsingPermisionHandler? {
            didSet { _audioStream.networkPermisionHandler = networkPermisionHandler }
        }
    #endif
    
    private lazy var _audioStream: AudioStream = {
        let a = AudioStream()
        a.delegate = self
        return a
    }()
    
    private var _url: URL?
    private var _reachability: Reachability?
    #if !os(OSX)
        private var _backgroundTask = UIBackgroundTaskInvalid
    #endif
    private var _lastSeekByteOffset: Position?
    private var _propertyLock: OSSpinLock = OS_SPINLOCK_INIT
    private var _internetConnectionAvailable = true
    
    private var _wasInterrupted = false
    private var _wasDisconnected = false
    private var _wasPaused = false

    private var _retryCount = 0
    private var _stopHandlerNetworkChange = false

    deinit {
        assert(Thread.isMainThread)
        NotificationCenter.default.removeObserver(self)
        stop()
        FreePlayer.removeIncompleteCache()
    }
    
    public init() {
        startReachability()
        addInteruptOb()
    }
    
    public convenience init(url target: URL) {
        self.init()
        _url = target
        reset()
    }
    
    
    
    private func addInteruptOb() {
        #if !os(OSX)
        /// RouteChange
        NotificationCenter.default.addObserver(forName: .AVAudioSessionRouteChange, object: nil, queue: OperationQueue.main) { [weak self](note) -> Void in
            let interuptionDict = note.userInfo
            // "Headphone/Line was pulled. Stopping player...."
            if let routeChangeReason = interuptionDict?[AVAudioSessionRouteChangeReasonKey] as? UInt, routeChangeReason == AVAudioSessionRouteChangeReason.oldDeviceUnavailable.rawValue {
                self?.pause()
            }
        }
        
        var playingStateBeforeInterrupte = false
        NotificationCenter.default.addObserver(forName: .AVAudioSessionInterruption, object: nil, queue: nil) { [weak self](note) -> Void in
            guard let sself = self else { return }
            let info = note.userInfo
            guard let type = info?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            if type == AVAudioSessionInterruptionType.began.rawValue {
                // 中断开始
                playingStateBeforeInterrupte = sself.isPlaying
                if playingStateBeforeInterrupte == true { sself.pause() }
            } else {
                // 中断结束
                guard let options = info?[AVAudioSessionInterruptionOptionKey] as? UInt, options == AVAudioSessionInterruptionOptions.shouldResume.rawValue, playingStateBeforeInterrupte == true else { return }
                sself.resume()
            }
        }
        #endif
    }
    
    
    private func reset() {
        _audioStream.reset()
        #if os(iOS)
            _audioStream.networkPermisionHandler = networkPermisionHandler
        #endif
        _audioStream.set(url: url, completion: {[unowned self] (success) in
            DispatchQueue.main.async {
                self._internetConnectionAvailable = true
                self._retryCount = 0
                self.play()
            }
        })
        _retryCount = 0
        _internetConnectionAvailable = true
        #if os(iOS)
            _backgroundTask = UIBackgroundTaskInvalid
            if StreamConfiguration.shared.automaticAudioSessionHandlingEnabled {
                do {
                    try AVAudioSession.sharedInstance().setCategory(AVAudioSessionCategoryPlayback)
                } catch {
                    fp_log("error:\(error)")
                }
            }
        #endif
    }
}

// MARK:  Public
extension FreePlayer {
    
    public func togglePlayPause() {
        assert(Thread.isMainThread)
        _wasPaused ? resume() : pause()
    }
    
    public func pause() {
        assert(Thread.isMainThread)
        _wasPaused = true
        _audioStream.pause()
    }
    
    public func resume() {
        assert(Thread.isMainThread)
        _wasPaused = false
        _audioStream.resume()
        #if os(iOS)
            NowPlayingInfo.shared.play(elapsedPlayback: Double(playbackPosition.timePlayed))
        #endif
    }
    
    public func play(from target: URL?){
        guard let u = target else { return }
        _url = u
        reset()
        play()
    }
    
    public func play() {
        assert(Thread.isMainThread)
        
        self._wasPaused = false
        if _audioStream.isPreloading {
            _audioStream.startCachedDataPlayback()
            return
        }
        #if os(iOS)
            self.endBackgroundTask()
            self._backgroundTask = UIApplication.shared.beginBackgroundTask(expirationHandler: {[weak self] in
                self?.endBackgroundTask()
            })
        #endif
        _audioStream.open()
        self.startReachability()
        
        /*
         guard let audio = _audioStream else { return }
         _wasPaused = false
         if audio.isPreloading {
         audio.startCachedDataPlayback()
         return
         }
         #if os(iOS)
         endBackgroundTask()
         _backgroundTask = UIApplication.shared.beginBackgroundTask(expirationHandler: {[weak self] in
         self?.endBackgroundTask()
         })
         #endif
         audio.open()
         startReachability()
         */
    }

    public func stop() {
        assert(Thread.isMainThread)
        _audioStream.forceStop = true
        _audioStream.reset()
        endBackgroundTask()
        _stopHandlerNetworkChange = true
    }
    
    public var volume: Float {
        get { return _audioStream.volume }
        set { _audioStream.volume = newValue }
    }
    
    public func rewind(in seconds: UInt) {
        DispatchQueue.main.async {
            let audio = self._audioStream
            if self.durationInSeconds <= 0 { return }  // Rewinding only possible for continuous streams
            let oriVolume = self.volume
            audio.volume = 0
            audio.rewind(in: seconds)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: {[weak self] in
                self?._audioStream.volume = oriVolume
            })
        }
    }
    
    public func preload() {
        DispatchQueue.main.async {
            self._audioStream.setPreloading(loading: true)
            self._audioStream.open()
        }
    }
    
    public func seek(to time: Float) {
        DispatchQueue.main.async {
            let duration = self.durationInSeconds
            if duration <= 0 { return }
            var offset = time / duration
            if offset > 1 { offset = 1 }
            if offset < 0 { offset = 0 }
            self._audioStream.resume()
            self._audioStream.seek(to: offset)
            #if os(iOS)
                NowPlayingInfo.shared.play(elapsedPlayback: Double(self.playbackPosition.timePlayed))
            #endif
        }
    }
    
    public func setPlayRate(to value: Float) {
        DispatchQueue.main.async {
            self._audioStream.set(playRate: value)
        }
    }
    
    public var isPlaying: Bool {
        assert(Thread.isMainThread)
        let state = _audioStream.state
        return state == .playing || state == .endOfFile
    }
    
    // MARK:  audio properties
    public var fileHint: AudioFileTypeID {
        assert(Thread.isMainThread)
        return _audioStream.fileHint
    }
    
    public var contentLength: UInt {
        assert(Thread.isMainThread)
        return _audioStream.contentLength
    }
    
    public var defaultContentLength: UInt {
        assert(Thread.isMainThread)
        return _audioStream.defaultContentLength
    }
    
    public var bufferRatio: Float {
        assert(Thread.isMainThread)
        let audio = _audioStream
        let length = Float(audio.contentLength)
        let read = Float(audio.bytesReceived)
        var final = length > 0 ? read / length : 0
        if final > 1 { final = 1 }
        if final < 0 { final = 0 }
        return final
    }
    
    public var prebufferedByteCount: Int {
        assert(Thread.isMainThread)
        return _audioStream.cachedDataSize
    }
    
    public var durationInSeconds: Float {
        assert(Thread.isMainThread)
        return _audioStream.duration
    }
    
    public var currentSeekByteOffset: Position {
        assert(Thread.isMainThread)
        var offset = Position()
        let audio = _audioStream
        if durationInSeconds <= 0 { return offset }// continuous
        offset.position = audio.playBackPosition.offset
        let pos = audio.streamPosition(for: offset.position)
        offset.start = pos.start
        offset.end   = pos.end
        return offset
    }
    
    public var bitRate: Float {
        assert(Thread.isMainThread)
        return _audioStream.bitrate
    }
    
    public var formatDescription: String {
        assert(Thread.isMainThread)
        return _audioStream.sourceFormatDescription
    }
    
    public var playbackPosition: PlaybackPosition {
        assert(Thread.isMainThread)
        return _audioStream.playBackPosition
    }
    
    public var cached: Bool {
        assert(Thread.isMainThread)
        guard let url = _url  else { return false }
        var config = StreamConfiguration.shared
        let fs = FileManager.default
        let id = config.cacheNaming.name(for: url)
        let cachedFile = (config.cacheDirectory as NSString).appendingPathComponent(id)
        var result = fs.fileExists(atPath: cachedFile)
        let additionalFolder = config.cachePolicy.additionalFolder
        if result == false, let storeFolder = additionalFolder   {
            let storedFile = (storeFolder as NSString).appendingPathComponent(id)
            result = fs.fileExists(atPath: storedFile)
        }
        return result
    }
    
    public var url: URL? {
        get {
            assert(Thread.isMainThread)
            return _url
        }
        set {
            _propertyLock.lock()
            if _url == newValue {
                _propertyLock.unlock()
                return
            }
            _url = newValue
            _audioStream.set(url: newValue, completion: {[unowned self] (success) in
                DispatchQueue.main.async {
                    self._internetConnectionAvailable = true
                    self._retryCount = 0
                    self.play()
                }
            })
            _propertyLock.unlock()
        }
    }
    
    // MARK:  methods
    private func endBackgroundTask() {
        #if os(iOS)
            guard _backgroundTask != UIBackgroundTaskInvalid else { return }
            UIApplication.shared.endBackgroundTask(_backgroundTask)
            _backgroundTask = UIBackgroundTaskInvalid
        #endif
    }
    
    func notify(state: AudioStreamState) {
        switch state {
        case .stopped:
            #if os(iOS)
                if StreamConfiguration.shared.automaticAudioSessionHandlingEnabled {
                    try? AVAudioSession.sharedInstance().setActive(false)
                }
                DispatchQueue.main.async {
                    NowPlayingInfo.shared.pause(elapsedPlayback: Double(self.playbackPosition.timePlayed))
                }
            #endif
        case .buffering: _internetConnectionAvailable = true
        case .playing:
            #if os(iOS)
                if StreamConfiguration.shared.automaticAudioSessionHandlingEnabled {
                    try? AVAudioSession.sharedInstance().setActive(true)
                }
                DispatchQueue.main.async {
                    let duration = Int(ceil(self.durationInSeconds))
                    if NowPlayingInfo.shared.duration != duration {
                        NowPlayingInfo.shared.duration = duration
                    }
                    if NowPlayingInfo.shared.playbackRate != 1 {
                        NowPlayingInfo.shared.play(elapsedPlayback: Double(self.playbackPosition.timePlayed))
                    }
                }
            #endif
            if _retryCount > 0 {
                _retryCount = 0
                onStateChange?(.retryingSucceeded)
            }
            endBackgroundTask()
        case .paused:
            #if os(iOS)
                DispatchQueue.main.async {
                    NowPlayingInfo.shared.pause(elapsedPlayback: Double(self.playbackPosition.timePlayed))
                }
            #endif
        case .failed:
            endBackgroundTask()
            #if os(iOS)
                NowPlayingInfo.shared.remove()
            #endif
        case .playbackCompleted: onComplete?()
        default: break
        }
        onStateChange?(state)
    }
    
    func attemptRestart() {
        let audio = _audioStream
        
        if audio.isPreloading {
            debug_log("☄️: Stream is preloading. Not attempting a restart")
            return
        }
        
        if _wasPaused {
            debug_log("☄️: Stream was paused. Not attempting a restart")
            return
        }
        
        if _internetConnectionAvailable == false {
            debug_log("☄️: Internet connection not available. Not attempting a restart")
            return
        }
        
        if _retryCount >= maxRetryCount {
            debug_log("☄️: Retry count \(_retryCount). Giving up.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: {[weak self] in
                self?.notify(state: .retryingFailed)
            })
            return
        }
        
        debug_log("☄️: Attempting restart.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: {[weak self] in
            self?.notify(state: .retryingStarted)
            self?.play()
        })
        _retryCount += 1
    }
    
    
    private func handleStateChanged(info: Reachability) {
        if _stopHandlerNetworkChange { return }
        DispatchQueue.main.async {
            let status = info.currentReachabilityStatus
            self._internetConnectionAvailable = status != .notReachable
            if self.isPlaying && self._internetConnectionAvailable == false {
                self._wasDisconnected = true
                debug_log("☄️: Internet connection disconnected while playing a stream.")
            }
            if self._wasDisconnected && self._internetConnectionAvailable {
                self._wasDisconnected = false
                if self._audioStream.streamHasDataCanPlay() == false {
                    self.attemptRestart()
                }
                debug_log("☄️: Internet connection available again.")
            }
        }
    }
    
    private func startReachability() {
        _stopHandlerNetworkChange = false
        guard _reachability == nil else { return }
        _reachability = Reachability(hostname: "www.baidu.com")
        _reachability?.whenReachable = {[weak self] info in
            self?.handleStateChanged(info: info)
        }
        _reachability?.whenUnreachable = { [weak self] info in
            self?.handleStateChanged(info: info)
        }
        try? _reachability?.startNotifier()
    }
    
    func isWifiAvailable() -> Bool {
        return _reachability?.isReachableViaWiFi ?? false
    }
}

// MARK: - AudioStreamDelegate
extension FreePlayer: AudioStreamDelegate {
    func audioStreamStateChanged(state: AudioStreamState) {
        fp_log("state:\(state)")
        func run() { notify(state: state) }
        #if !os(OSX)
            if #available(iOS 10.0, *) {
                RunLoop.current.perform {
                    self.notify(state: state)
                }
            } else {
                run()
            }
        #else
            if #available(OSX 10.12, *) {
                RunLoop.current.perform {
                    self.notify(state: state)
                }
            } else {
                run()
            }
        #endif
    }
    
    func audioStreamErrorOccurred(errorCode: AudioStreamError , errorDescription: String) {
        onFailure?(errorCode, errorDescription)
        let needRestart: [AudioStreamError] = [.network, .unsupportedFormat, .open, .terminated]
        if _audioStream.isPreloading == false && needRestart.contains(errorCode) {
            attemptRestart()
            fp_log("audioStreamErrorOccurred attemptRestart")
        }
    }
    
    func audioStreamMetaDataAvailable(metaData: [MetaDataKey : Metadata]) {
        #if os(iOS)
            guard StreamConfiguration.shared.autoFillID3InfoToNowPlayingCenter else { return }
            DispatchQueue.global(qos: .utility).async {
                if let value = metaData[.title], case Metadata.text(let title) = value {
                    NowPlayingInfo.shared.name = title
                }
                if let value = metaData[.album], case Metadata.text(let album) = value {
                    NowPlayingInfo.shared.album = album
                }
                if let value = metaData[.artist], case Metadata.text(let artist) = value {
                    NowPlayingInfo.shared.artist = artist
                }
                if let value = metaData[.cover], case Metadata.data(let cover) = value {
                    NowPlayingInfo.shared.artwork = UIImage(data: cover)
                }
                NowPlayingInfo.shared.update()
            }
            
        #endif
    }
    
    func samplesAvailable(samples: UnsafeMutablePointer<AudioBufferList>, frames: UInt32, description: AudioStreamPacketDescription) {
        
    }
    
    func bitrateAvailable() {
        let config = StreamConfiguration.shared
        
        guard config.usePrebufferSizeCalculationInSeconds == false else { return }
        
        let bitrate = _audioStream.bitrate
        if bitrate <= 0 { return } // No bitrate provided, use the defaults
        
        let bufferSizeForSecond = bitrate / 8.0
        
        var bufferSize = bufferSizeForSecond * Float(config.requiredPrebufferSizeInSeconds)
        
        if bufferSize < 50000 { bufferSize = 50000 } // Check that we still got somewhat sane buffer size
        
        if self.durationInSeconds <= 0 {
            // continuous
            if bufferSize > Float(config.requiredInitialPrebufferedByteCountForContinuousStream) {
                bufferSize = Float(config.requiredInitialPrebufferedByteCountForContinuousStream)
            }
        } else {
            if bufferSize > Float(config.requiredInitialPrebufferedByteCountForNonContinuousStream) {
                bufferSize = Float(config.requiredInitialPrebufferedByteCountForNonContinuousStream)
            }
        }
        // Update the configuration
        StreamConfiguration.shared.requiredInitialPrebufferedByteCountForContinuousStream = Int(bufferSize)
        StreamConfiguration.shared.requiredInitialPrebufferedByteCountForNonContinuousStream = Int(bufferSize)
    }
}

// MARK: Static Function
extension FreePlayer {
    
    public static func totalCachedObjectsSize() -> UInt64 {
        var total = UInt64()
        let fs = FileManager.default
        let dir = StreamConfiguration.shared.cacheDirectory
        do {
            let folder = dir as NSString
            let files = try fs.contentsOfDirectory(atPath: dir)
            for item in files {
                let path = folder.appendingPathComponent(item)
                let attributes = try fs.attributesOfItem(atPath: path)
                if let size = attributes[FileAttributeKey.size] as? UInt64 {
                    total += size
                }
            }
        } catch { debug_log(error) }
        return total
    }
    
    public static func expungeCacheFolder() {
        DispatchQueue.global(qos: .utility).async {
            let fs = FileManager.default
            let dir = StreamConfiguration.shared.cacheDirectory
            do {
                try fs.removeItem(atPath: dir)
                try fs.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
            } catch {
                debug_log(error)
            }
        }
    }
    
    public static func removeCache(by url: URL?) {
        guard let raw = url else { return }
        DispatchQueue.global(qos: .utility).async {
            let fs = FileManager.default
            let id = StreamConfiguration.shared.cacheNaming.name(for: raw)
            let dir = StreamConfiguration.shared.cacheDirectory
            do {
                let folder = dir as NSString
                let files = try fs.contentsOfDirectory(atPath: dir)
                for item in files {
                    guard item.hasPrefix(id) else { continue }
                    let path = folder.appendingPathComponent(item)
                    try fs.removeItem(atPath: path)
                }
            } catch {
                debug_log(error)
            }
        }
    }
    
    public static func removeIncompleteCache() {
        DispatchQueue.global(qos: .utility).async {
            let fs = FileManager.default
            let dir = StreamConfiguration.shared.cacheDirectory
            do {
                let folder = dir as NSString
                let files = try fs.contentsOfDirectory(atPath: dir)
                for item in files {
                    if item.hasSuffix(".tmp") {
                        let path = folder.appendingPathComponent(item)
                        try fs.removeItem(atPath: path)
                    }
                }
            } catch {
                debug_log(error)
            }
        }
    }
}

