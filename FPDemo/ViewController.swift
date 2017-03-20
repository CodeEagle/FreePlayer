//
//  ViewController.swift
//  FPDemo
//
//  Created by Lincoln Law on 2017/2/21.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//

import UIKit
import FreePlayer
class ViewController: UIViewController {
    private var _localMP3: URL?
    private var _player: FreePlayer?
    
    private var _butttonReset = UIButton(frame: CGRect(x: 100, y: 100, width: 100, height: 50))
    private var _butttonClear = UIButton(frame: CGRect(x: 100, y: 200, width: 100, height: 50))
    private var _butttonSeek = UIButton(frame: CGRect(x: 100, y: 300, width: 100, height: 50))
    
    private var _slider = UISlider(frame: CGRect(x: 100, y: 360, width: 200, height: 20))
    
    override func viewDidLoad() {
        super.viewDidLoad()
        StreamConfiguration.shared.cacheEnabled = false
        StreamConfiguration.shared.autoFillID3InfoToNowPlayingCenter = true
        view.addSubview(_butttonReset)
        view.addSubview(_butttonClear)
        view.addSubview(_butttonSeek)
        view.addSubview(_slider)
        
        _butttonReset.backgroundColor = UIColor.orange
        _butttonClear.backgroundColor = UIColor.orange
        _butttonSeek.backgroundColor = UIColor.orange
        
        _butttonReset.setTitle("Reset", for: .normal)
        _butttonClear.setTitle("Clean", for: .normal)
        _butttonSeek.setTitle("Seek", for: .normal)
        
        _butttonReset.addTarget(self, action: #selector(ViewController.reset), for: .touchUpInside)
        _butttonClear.addTarget(self, action: #selector(ViewController.clean), for: .touchUpInside)
        _butttonSeek.addTarget(self, action: #selector(ViewController.seek), for: .touchUpInside)
        _slider.addTarget(self, action: #selector(ViewController.valueChange), for: .valueChanged)
        
//        FPLogger.enable(modules: [FPLogger.Module.httpStream])
        _slider.maximumValue = 1
        _slider.minimumValue = 0
//        FPLogger.shared.logToFile = false
//        StreamConfiguration.shared.requireNetworkChecking = false
//        print(StreamConfiguration.shared)
        _localMP3 = Bundle.main.url(forResource: "久远-光と波の记忆", withExtension: "mp3")
        //"http://mp3-cdn.luoo.net/low/luoo/radio895/03.mp3"
        //"http://199.180.75.58:9061/stream"
//        _localMP3 = URL(string: "http://mp3-cdn.luoo.net/low/package/neoclassic01/radio01/03.mp3")
        // Do any additional setup after loading the view, typically from a nib.
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }
    @objc private func valueChange() {
        _player?.volume = _slider.value
    }
    
    @objc private func reset() {
        if _player == nil {
            _player = FreePlayer()
            _player?.networkPermisionHandler = { done in
                done(true)
            }
        }
        _player?.play(from: _localMP3)
        NowPlayingInfo.shared.image(with: "http://img-cdn.luoo.net/pics/vol/58a9c994116ae.jpg")
    }
    
    @objc private func seek() {
        _player?.seek(to: 30)
    }
    
    @objc private func clean() {
        _player = nil
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    open override var canBecomeFirstResponder: Bool { return true }
    open override func remoteControlReceived(with event: UIEvent?) {
        guard let value = event?.subtype else { return }
        let manager = _player
        let playing = _player?.isPlaying ?? false
        switch value {
        case .remoteControlPause: manager?.pause()
        case .remoteControlPlay: manager?.resume()
        case .remoteControlTogglePlayPause: playing ? manager?.pause() : manager?.resume()
        case .remoteControlNextTrack, .remoteControlBeginSeekingForward: break//manager.next()
        case .remoteControlPreviousTrack, .remoteControlBeginSeekingBackward: break//manager.previous()
        default: break
        }
    }
    

}

