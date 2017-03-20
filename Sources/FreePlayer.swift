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
    public var networkPermisionHandler: FPNetworkUsingPermisionHandler? {
        didSet { _audioStream?.networkPermisionHandler = networkPermisionHandler }
    }
    
    fileprivate var _audioStream: AudioStream?
    fileprivate var _url: URL?
    fileprivate var _reachability: Reachability?
    fileprivate var _backgroundTask = UIBackgroundTaskInvalid
    fileprivate var _lastSeekByteOffset: Position?
    fileprivate var _propertyLock: OSSpinLock = OS_SPINLOCK_INIT
    fileprivate var _internetConnectionAvailable = true
    
    fileprivate var _wasInterrupted = false
    fileprivate var _wasDisconnected = false
    fileprivate var _wasPaused = false

    fileprivate var _retryCount = 0
    fileprivate var _stopHandlerNetworkChange = false

    deinit {
        assert(Thread.isMainThread)
        NotificationCenter.default.removeObserver(self)
        stop()
        _audioStream = nil
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
    }
    
    fileprivate func reset() {
        _audioStream?.clean()
        _audioStream = AudioStream()
        _audioStream?.delegate = self
        _audioStream?.networkPermisionHandler = networkPermisionHandler
        _audioStream?.networkPermisionHandlerExecuteResponse = {[weak self] in
            guard let sself = self else { return }
            DispatchQueue.main.async {
                sself._internetConnectionAvailable = true
                sself._retryCount = 0
                sself.play()
            }
        }
        _audioStream?.set(url: url)
        _retryCount = 0
        _internetConnectionAvailable = true
        #if os(iOS)
            _backgroundTask = UIBackgroundTaskInvalid
            if StreamConfiguration.shared.automaticAudioSessionHandlingEnabled {
                do {
                    try AVAudioSession.sharedInstance().setCategory(AVAudioSessionCategoryPlayback)
                } catch {
                    fp_log(error)
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
        guard let audio = _audioStream else { return }
        _wasPaused = true
        audio.pause()
    }
    
    public func resume() {
        assert(Thread.isMainThread)
        guard let audio = _audioStream else { return }
        _wasPaused = false
        audio.resume()
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
    }
    
    public func stop() {
        assert(Thread.isMainThread)
        _audioStream?.close(withParser: true)
        endBackgroundTask()
        _stopHandlerNetworkChange = true
//        self._reachability?.stopNotifier()
//        self._reachability = nil
    }
    
    public var volume: Float {
        get { return _audioStream?.volume ?? 1 }
        set { _audioStream?.volume = newValue }
    }
    
    public func rewind(in seconds: UInt) {
        DispatchQueue.main.async {
            guard let audio = self._audioStream else { return }
            if self.durationInSeconds <= 0 { return }  // Rewinding only possible for continuous streams
            let oriVolume = self.volume
            audio.volume = 0
            audio.rewind(in: seconds)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: {[weak self] in
                self?._audioStream?.volume = oriVolume
            })
        }
    }
    
    public func preload() {
        DispatchQueue.main.async {
            self._audioStream?.setPreloading(loading: true)
            self._audioStream?.open()
        }
    }
    
    public func seek(to time: Float) {
        DispatchQueue.main.async {
            let duration = self.durationInSeconds
            if duration <= 0 { return }
            var offset = time / duration
            if offset > 1 { offset = 1 }
            if offset < 0 { offset = 0 }
            self._audioStream?.resume()
            self._audioStream?.seek(to: offset)
            #if os(iOS)
                NowPlayingInfo.shared.play(elapsedPlayback: Double(self.playbackPosition.timePlayed))
            #endif
        }
    }
    
    public func setPlayRate(to value: Float) {
        DispatchQueue.main.async {
            self._audioStream?.set(playRate: value)
        }
    }
    
    public var isPlaying: Bool {
        assert(Thread.isMainThread)
        guard let state = _audioStream?.state else { return false }
        return state == .playing || state == .endOfFile
    }
    
    // MARK:  audio properties
    public var contentType: String? {
        assert(Thread.isMainThread)
        return _audioStream?.contentType
    }
    
    public var contentLength: UInt64 {
        assert(Thread.isMainThread)
        return _audioStream?.contentLength ?? 0
    }
    
    public var defaultContentLength: UInt64 {
        assert(Thread.isMainThread)
        return _audioStream?.defaultContentLength ?? 0
    }
    
    public var bufferRatio: Float {
        assert(Thread.isMainThread)
        guard let audio = _audioStream else { return 0 }
        let length = Float(audio.contentLength)
        let read = Float(audio.bytesReceived)
        return length > 0 ? read / length : 0
    }
    
    public var outputFileURL: URL? {
        get {
            assert(Thread.isMainThread)
            return _audioStream?.outputFileURL()
        }
        set { _audioStream?.setOuput(file: newValue) }
    }
    
    public var prebufferedByteCount: Int {
        assert(Thread.isMainThread)
        return _audioStream?.cachedDataSize ?? 0
    }
    
    public var durationInSeconds: Float {
        assert(Thread.isMainThread)
        return _audioStream?.duration ?? 0
    }
    
    public var currentSeekByteOffset: Position {
        assert(Thread.isMainThread)
        var offset = Position()
        guard let audio = _audioStream else { return offset }
        if durationInSeconds <= 0 { return offset }// continuous
        offset.position = audio.playBackPosition.offset
        let pos = audio.streamPosition(for: offset.position)
        offset.start = pos.start
        offset.end   = pos.end
        return offset
    }
    
    public var bitRate: Float {
        assert(Thread.isMainThread)
        return _audioStream?.bitrate ?? 0
    }
    
    public var formatDescription: String {
        assert(Thread.isMainThread)
        return _audioStream?.sourceFormatDescription ?? ""
    }
    
    public var playbackPosition: PlaybackPosition {
        assert(Thread.isMainThread)
        return _audioStream?.playBackPosition ?? PlaybackPosition()
    }
    
    public var cached: Bool {
        assert(Thread.isMainThread)
        guard let url = _url  else { return false }
        let config = StreamConfiguration.shared
        let fs = FileManager.default
        let id = AudioStream.createIdentifier(for: url) + ".metadata"
        let cachedFile = (config.cacheDirectory as NSString).appendingPathComponent(id)
        var result = fs.fileExists(atPath: cachedFile)
        if let storeFolder = config.storeDirectory, result == false {
            let storedFile = (storeFolder as NSString).appendingPathComponent(id)
            result = fs.fileExists(atPath: storedFile)
        }
        return result
    }
    
    public var suggestedFileExtension: String? {
        assert(Thread.isMainThread)
        guard let type = contentType else { return nil }
        let map = [
            "mpeg" : "mp3",
            "x-wav" : "wav",
            "x-aifc" : "aifc",
            "x-aiff" : "aiff",
            "x-m4a" : "m4a",
            "mp4" : "mp4",
            "x-caf" : "caf",
            "aac" : "aac",
            "aacp" : "aac"
        ]
        for (key, value) in map {
            if type.hasSuffix(key) { return value }
        }
        return nil
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
            _audioStream?.set(url: newValue)
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
            if StreamConfiguration.shared.automaticAudioSessionHandlingEnabled {
                try? AVAudioSession.sharedInstance().setActive(false)
            }
            #if os(iOS)
                NowPlayingInfo.shared.pause(elapsedPlayback: Double(playbackPosition.timePlayed))
            #endif
        case .buffering: _internetConnectionAvailable = true
        case .playing:
            
            if StreamConfiguration.shared.automaticAudioSessionHandlingEnabled {
                try? AVAudioSession.sharedInstance().setActive(true)
            }
            #if os(iOS)
                let duration = Int(ceil(durationInSeconds))
                if NowPlayingInfo.shared.duration != duration {
                    NowPlayingInfo.shared.duration = duration
                }
                if NowPlayingInfo.shared.playbackRate != 1 {
                    NowPlayingInfo.shared.play(elapsedPlayback: Double(playbackPosition.timePlayed))
                }
            #endif
            if _retryCount > 0 {
                _retryCount = 0
                onStateChange?(.retryingSucceeded)
            }
            endBackgroundTask()
        case .paused:
            #if os(iOS)
                NowPlayingInfo.shared.pause(elapsedPlayback: Double(playbackPosition.timePlayed))
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
        guard let audio = _audioStream else { return }
        
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
                if self._audioStream?.streamHasDataCanPlay() == false {
                    self.attemptRestart()
                }
                debug_log("☄️: Internet connection available again.")
            }
        }
    }
    
    fileprivate func startReachability() {
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
        if #available(iOS 10.0, *) {
            RunLoop.current.perform {
                self.notify(state: state)
            }
        } else { notify(state: state) }
    }
    
    func audioStreamErrorOccurred(errorCode: AudioStreamError , errorDescription: String) {
        let needRestart: [AudioStreamError] = [.network, .unsupportedFormat, .open, .terminated]
        if _audioStream?.isPreloading == false && needRestart.contains(errorCode) {
            attemptRestart()
            fp_log("audioStreamErrorOccurred attemptRestart")
        }
    }
    
    func audioStreamMetaDataAvailable(metaData: [String : Metadata]) {
        #if os(iOS)
            DispatchQueue.global(qos: .userInitiated).async {
                var artist: String?
                var title: String?
                var cover: UIImage?
                if let raw = metaData[HttpStream.Keys.icecastStationName.rawValue], case Metadata.text(let name) = raw {
                    title = name
                }
                if StreamConfiguration.shared.autoFillID3InfoToNowPlayingCenter {
                    if let raw = metaData[ID3Parser.MetaDataKey.title.rawValue], case Metadata.text(let t) = raw {
                        title = t
                    }
                    if let raw = metaData[ID3Parser.MetaDataKey.artist.rawValue], case Metadata.text(let art) = raw {
                        artist = art
                    }
                    if let raw = metaData[ID3Parser.MetaDataKey.cover.rawValue], case Metadata.data(let d) = raw {
                        cover = UIImage(data: d)
                    }
                }
                if let value = artist { NowPlayingInfo.shared.artist = value }
                if let value = title { NowPlayingInfo.shared.name = value }
                if let value = cover { NowPlayingInfo.shared.artwork = value }
                NowPlayingInfo.shared.update()
            }
        #endif
    }
    
    func samplesAvailable(samples: UnsafeMutablePointer<AudioBufferList>, frames: UInt32, description: AudioStreamPacketDescription) {
        
    }
    
    func bitrateAvailable() {
        let config = StreamConfiguration.shared
        
        guard config.usePrebufferSizeCalculationInSeconds == false else { return }
        
        let bitrate = _audioStream?.bitrate ?? 0
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
                guard item.hasSuffix(".dou") || item.hasSuffix(".metadata") else { continue }
                let path = folder.appendingPathComponent(item)
                let attributes = try fs.attributesOfItem(atPath: path)
                if let size = attributes[FileAttributeKey.size] as? UInt64 {
                    total += size
                }
            }
        } catch {
            debug_log(error)
        }
        return total
    }
    
    public static func expungeCacheFolder() {
        DispatchQueue.global(qos: .userInitiated).async {
            let fs = FileManager.default
            let dir = StreamConfiguration.shared.cacheDirectory
            do {
                let folder = dir as NSString
                let files = try fs.contentsOfDirectory(atPath: dir)
                for item in files {
                    guard item.hasSuffix(".dou") || item.hasSuffix(".metadata") else { continue }
                    let path = folder.appendingPathComponent(item)
                    try fs.removeItem(atPath: path)
                }
            } catch {
                debug_log(error)
            }
        }
    }
    
    public static func removeCache(by url: URL?) {
        guard let raw = url else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let fs = FileManager.default
            let id = AudioStream.createIdentifier(for: raw)
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
        DispatchQueue.global(qos: .userInitiated).async {
            let fs = FileManager.default
            let dir = StreamConfiguration.shared.cacheDirectory
            do {
                let folder = dir as NSString
                let files = try fs.contentsOfDirectory(atPath: dir)
                for item in files {
                    if item.hasSuffix(".dou"), !files.contains(item + ".metadata") {
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

