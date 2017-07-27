//
//  ViewController.swift
//  FreePlayerOSXDemo
//
//  Created by lincolnlaw on 2017/7/27.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//

import Cocoa
import FreePlayer
class ViewController: NSViewController {
    
    private var _localMP3: URL?
    private var _player: FreePlayer?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        _localMP3 = URL(string: "http://mp3-cdn2.luoo.net/low/package/vinyl01/radio32/06.mp3")
//        _localMP3 = Bundle.main.url(forResource: "久远-光と波の记忆", withExtension: "mp3")
        if _player == nil {
            _player = FreePlayer()
        }
        _player?.play(from: _localMP3)
        // Do any additional setup after loading the view.
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }


}

