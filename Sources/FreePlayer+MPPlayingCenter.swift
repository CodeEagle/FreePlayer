//
//  FreePlayer+MPPlayingCenter.swift
//  FreePlayer
//
//  Created by Lincoln Law on 2017/3/1.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//

import MediaPlayer
#if os(iOS)
    public final class NowPlayingInfo {
        public static var shared = NowPlayingInfo()
        public var name = ""
        public var artist = ""
        public var album = ""
        public var artwork = UIImage()
        public var duration = 0
        public var playbackRate = Double()
        public var playbackTime = Double()
        private var _lock: OSSpinLock = OS_SPINLOCK_INIT
        private var _coverTask: URLSessionDataTask?
        private init() { }
        
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
            DispatchQueue.global(qos: .userInteractive).async {
                let request = URLRequest(url: r, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20)
                if let d = URLCache.shared.cachedResponse(for: request)?.data, let image = UIImage(data: d)  {
                    debug_log("cover from cache")
                    DispatchQueue.main.async {
                        self._lock.lock()
                        self.artwork = image
                        self._lock.unlock()
                        self.update()
                    }
                    return
                }
                let task = URLSession.shared.dataTask(with: request, completionHandler: { [weak self](data, resp, _) in
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
    }
#endif

