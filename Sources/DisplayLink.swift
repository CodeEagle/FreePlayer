//
//  DisplayLink.swift
//  FreePlayer
//
//  Created by lincolnlaw on 2017/7/26.
//  Copyright © 2017年 LawLincoln. All rights reserved.
//

import Foundation
import QuartzCore

#if !os(OSX)
    typealias DisplayLink = CADisplayLink
    extension CADisplayLink {
        func start() {
            isPaused = false
        }
        func stop() {
            isPaused = true
        }
    }
#else
    typealias DisplayLink = CVDisplayLink
    extension CVDisplayLink {
        func invalidate() {
            stop()
        }
        func start() {
            CVDisplayLinkStart(self)
        }
        func stop() {
            CVDisplayLinkStop(self)
        }
    }
#endif

public final class FreeDisplayLink {
    
    private var _callbackHanlder: () -> Void = { }
    private var displayLink: DisplayLink?
    
    init(update: () -> Void) {
        createDisplayLink()
    }
    
    private func update() {
        _callbackHanlder()
    }
    
    func invalidate() {
        displayLink?.invalidate()
    }
    
    func stop() {
        displayLink?.stop()
    }
    
    func start() {
        displayLink?.start()
    }
    
    var isPaused: Bool = false {
        didSet {
            isPaused ? displayLink?.stop() : displayLink?.start()
        }
    }
    
}
extension FreeDisplayLink {
    #if !os(OSX)
    
    func createDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(newFrame(_:)))
        displayLink?.add(to: .main, forMode: .commonModes)
    }
    
    @objc private func newFrame(_ displayLink: CADisplayLink) {
        update()
    }
    #else
    func createDisplayLink() {
        func callback(link: CVDisplayLink,
                      inNow: UnsafePointer<CVTimeStamp>, //wtf is this?
            inOutputTime: UnsafePointer<CVTimeStamp>,
            flagsIn: CVOptionFlags,
            flagsOut: UnsafeMutablePointer<CVOptionFlags>,
            displayLinkContext: UnsafeMutableRawPointer?) -> CVReturn {
            unsafeBitCast(displayLinkContext, to: FreeDisplayLink.self).update()
            return kCVReturnSuccess
        }
        
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let displayLink = displayLink else {
            fatalError("Unable to create a CVDisplayLink?")
        }
        CVDisplayLinkSetOutputCallback(displayLink, callback, unsafeBitCast(self, to: UnsafeMutableRawPointer.self))
        CVDisplayLinkStart(displayLink)
    }
    #endif
}
