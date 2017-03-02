//
//  Global.swift
//  FreePlayer
//
//  Created by Lincoln Law on 2017/2/28.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//

import AudioToolbox

// MARK: - Structure
public enum AudioStreamState { case stopped, buffering, playing, paused, seeking, failed, endOfFile, playbackCompleted, retryingStarted, retryingSucceeded, retryingFailed }

public enum AudioStreamError: Int {
    case none, open, streamParse, network, unsupportedFormat, streamBouncing, terminated
}

public struct PlaybackPosition {
    public var offset = Float()
    public var timePlayed = Float()
    public init() { }
}

public struct Position {
    public var start = UInt64()
    public var end = UInt64()
    public var position = Float()
    public init() { }
}

public typealias FPNetworkUsingPermisionHandler = ((Bool) -> Void) -> Void

