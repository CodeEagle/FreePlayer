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
    private var _player = FreePlayer()
    
    override func viewDidLoad() {
        super.viewDidLoad()
//        _localMP3 = URL(string: "http://mp3-cdn2.luoo.net/low/package/vinyl01/radio32/06.mp3")!
//        _localMP3 = Bundle.main.url(forResource: "久远-光と波の记忆", withExtension: "mp3")
        _localMP3 = URL(string: "http://mp3-cdn.luoo.net/low/package/neoclassic01/radio01/03.mp3")
//        _localMP3 = URL(string: "http://87.98.216.129:4240/;?icy=http")
//        _localMP3 = URL(string: "http://94.23.148.11:8392/stream?icy=http")
        _player.play(from: _localMP3)
        // Do any additional setup after loading the view.
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }


}

