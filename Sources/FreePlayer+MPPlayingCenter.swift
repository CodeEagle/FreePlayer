//
//  FreePlayer+MPPlayingCenter.swift
//  FreePlayer
//
//  Created by Lincoln Law on 2017/3/1.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//

import MediaPlayer
#if os(iOS)
    public final class NowPlayingInfo: NSObject {
        public static var shared = NowPlayingInfo()
        private var session = URLSession.shared
        public var name = "" { didSet { FPLogger.write(msg: "🎹:\(name)") } }
        public var artist = ""
        public var album = ""
        public var artwork = UIImage() { didSet { didSetImage() } }
        public var duration = 0
        public var playbackRate = Double()
        public var playbackTime = Double()
        public var didSetImage: () -> () = {}
        private var _lock: OSSpinLock = OS_SPINLOCK_INIT
        private var _coverTask: URLSessionDataTask?
        private var _backgroundTask = UIBackgroundTaskInvalid
        private override init() { }
        
        var info: [String : Any] {
            var map = [String : Any]()
            _lock.lock()
            map[MPMediaItemPropertyTitle] = name
            map[MPMediaItemPropertyArtist] = artist
            map[MPMediaItemPropertyAlbumTitle] = album
            map[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(image: artwork)
            map[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playbackTime
            map[MPNowPlayingInfoPropertyPlaybackRate] = playbackRate
            map[MPMediaItemPropertyPlaybackDuration] = duration
            _lock.unlock()
            return map
        }
        
        public func play(elapsedPlayback: Double) {
            playbackTime = elapsedPlayback
            playbackRate = 1
            update()
        }
        
        public func pause(elapsedPlayback: Double) {
            playbackTime = elapsedPlayback
            playbackRate = 0
            update()
        }
        
        public func image(with url: String?) {
            guard let u = url, let r = URL(string: u) else { return }
            _coverTask?.cancel()
            endBackgroundTask()
            DispatchQueue.global(qos: .userInteractive).async {
                let request = URLRequest(url: r, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20)
                if let d = URLCache.shared.cachedResponse(for: request)?.data, let image = UIImage(data: d)  {
                    DispatchQueue.main.async {
                        self._lock.lock()
                        self.artwork = image
                        self._lock.unlock()
                        self.update()
                    }
                    return
                }
               self.startBackgroundTask()
                let task = self.session.dataTask(with: request, completionHandler: { [weak self](data, resp, _) in
                    self?.endBackgroundTask()
                    if let r = resp, let d = data {
                        let cre = CachedURLResponse(response: r, data: d)
                        URLCache.shared.storeCachedResponse(cre, for: request)
                    }
                    DispatchQueue.main.async {
                        guard let sself = self, let d = data, let image = UIImage(data: d) else { return }
                        sself._lock.lock()
                        sself.artwork = image
                        sself._lock.unlock()
                        sself.update()
                    }
                })
                task.resume()
                self._coverTask = task
            }
        }
        
        public func update() {
            DispatchQueue.main.async {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = self.info
            }
        }
        
        public func remove() {
            _lock.lock()
            name = ""
            artist = ""
            album = ""
            artwork = UIImage()
            duration = 0
            playbackRate = Double()
            playbackTime = Double()
            _lock.unlock()
            DispatchQueue.main.async {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
        }
        
        private func startBackgroundTask() {
            endBackgroundTask()
            _backgroundTask = UIApplication.shared.beginBackgroundTask(expirationHandler: {[weak self] in
                self?.endBackgroundTask()
            })
        }
        
        private func endBackgroundTask() {
            guard _backgroundTask != UIBackgroundTaskInvalid else { return }
            UIApplication.shared.endBackgroundTask(_backgroundTask)
            _backgroundTask = UIBackgroundTaskInvalid
        }
        
        func updateProxy() {
            let config = StreamConfiguration.shared
            if  config.usingCustomProxy {
                guard config.customProxyHttpHost.isEmpty == false, config.customProxyHttpPort != 0 else { return }
                let configure = URLSessionConfiguration.default
                let enableKey = kCFNetworkProxiesHTTPEnable as String
                let hostKey = kCFNetworkProxiesHTTPProxy as String
                let portKey = kCFNetworkProxiesHTTPPort as String
                configure.connectionProxyDictionary = [
                    enableKey : 1,
                    hostKey : config.customProxyHttpHost,
                    portKey : config.customProxyHttpPort
                ]
                session = URLSession(configuration: configure, delegate: self, delegateQueue: .main)
            } else {
                NowPlayingInfo.shared.session = URLSession.shared
            }
        }
    }
    
    // MARK: - URLSessionDelegate, URLSessionTaskDelegate
    extension NowPlayingInfo: URLSessionDelegate, URLSessionTaskDelegate {
        public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let config = StreamConfiguration.shared
            let isDigestMehod = challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest
            if challenge.previousFailureCount == 0, isDigestMehod {
                let credential = URLCredential(user: config.customProxyUsername, password: config.customProxyPassword, persistence: URLCredential.Persistence.forSession)
                completionHandler(URLSession.AuthChallengeDisposition.useCredential, credential)
            } else {
                completionHandler(URLSession.AuthChallengeDisposition.useCredential, nil)
            }
        }
    }
#endif

