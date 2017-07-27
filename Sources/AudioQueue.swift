//
//  AudioQueue.swift
//  FreePlayer
//
//  Created by Lincoln Law on 2017/2/19.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//

import AudioToolbox
// MARK: - AudioQueueDelegate
protocol AudioQueueDelegate: class {
    func audioQueueStateChanged(state: AudioQueue.State)
    func audioQueueBuffersEmpty()
    func audioQueueInitializationFailed()
    func audioQueueFinishedPlayingPacket()
}
// MARK: - AudioQueue
final class AudioQueue {
    enum State { case idle, running, paused, unknown }
    
    weak var delegate: AudioQueueDelegate?
    var streamDesc: AudioStreamBasicDescription?
    var initialOutputVolume: Float = 0
    var lastError: OSStatus = noErr
    
    var initialized: Bool { return _outAQ != nil }
    
    var volume: Float {
        get {
            guard let queue = _outAQ else { return 1 }
            var vol: Float = 0
            if AudioQueueGetParameter(queue, kAudioQueueParam_Volume, &vol) == noErr {
                return vol
            }
            return 1
        }
        set {
            guard let queue = _outAQ else { return }
            AudioQueueSetParameter(queue, kAudioQueueParam_Volume, newValue).check(operation: "set volume error")
        }
    }
    
    var currentState: State {
        var s = State.unknown
        _mutex.lock()
        s = _state
        _mutex.unlock()
        return s
    }
    
    private var _state: State = .unknown
    private var _outAQ: AudioQueueRef?// the audio queue
    
    private var _audioQueueBuffer: UnsafeMutablePointer<AudioQueueBufferRef?>?// audio queue buffers
    private var _packetDescs: [AudioStreamPacketDescription] = []// packet descriptions for enqueuing audio
    // the index of the audioQueueBuffer that is being filled
    private var _fillBufferIndex = UInt32()
    // how many bytes have been filled
    private var _bytesFilled = UInt32()
    // how many packets have been filled
    private var _packetsFilled = UInt32()
    // how many buffers are used
    private var _buffersUsed = UInt32()
    // flag to indicate that the queue has been started
    private var _audioQueueStarted = false
    // flags to indicate that a buffer is still in use
    private var _bufferInUse: UnsafeMutablePointer<Bool>?
    private var _levelMeteringEnabled = false
    
    private var _mutex: OSSpinLock = OS_SPINLOCK_INIT
    private var _bufferInUseMutex: pthread_mutex_t = .init()
    private var _bufferFreeCondition: pthread_cond_t = .init()
    

    deinit {
        stop(immediately: true)
        cleanup()
        
        let config = StreamConfiguration.shared
        let bufferCount = Int(config.bufferCount)
        _audioQueueBuffer?.deallocate(capacity: bufferCount)
        _bufferInUse?.deallocate(capacity: bufferCount)
        
        pthread_mutex_destroy(&_bufferInUseMutex)
        pthread_cond_destroy(&_bufferFreeCondition)
    }
    
    init() {
        let config = StreamConfiguration.shared
        let bufferCount = Int(config.bufferCount)
        _packetDescs = Array(repeating: AudioStreamPacketDescription(), count: Int(config.maxPacketDescs))
        _audioQueueBuffer = UnsafeMutablePointer<AudioQueueBufferRef?>.allocate(capacity: bufferCount)
        _bufferInUse = UnsafeMutablePointer<Bool>.allocate(capacity: bufferCount)
        for i in 0..<bufferCount { _bufferInUse?.advanced(by: i).pointee = false }
        if pthread_mutex_init(&_bufferInUseMutex, nil) != 0 { aq_log("_bufferInUseMutex init failed!") }
        if pthread_cond_init(&_bufferFreeCondition, nil) != 0 { aq_log("_bufferFreeCondition init failed!") }
    }
}

// MARK: - Public
extension AudioQueue {
    
    func start() {
        if _audioQueueStarted { return }
        guard let queue = _outAQ else { return }
        let err = AudioQueueStart(queue, nil)
        if err == noErr {
            _audioQueueStarted = true
            _levelMeteringEnabled = false
            lastError = noErr
        } else {
            aq_log("AudioQueueStart failed!");
            lastError = err
        }
    }
    func pause() {
        let cstate = currentState
        if cstate == .running {
            if let queue = _outAQ, AudioQueuePause(queue) != noErr {
                aq_log("AudioQueuePause failed!")
            }
            state = .paused
        }
    }
    
    func resume() {
        let cstate = currentState
        if cstate == .paused, let queue = _outAQ {
            AudioQueueStart(queue, nil)
            state = .running
        }
    }
    
    func stop(immediately: Bool = false) {
        if !_audioQueueStarted {
            aq_log("audio queue already stopped, return!")
            return
        }
        _audioQueueStarted = false
        _levelMeteringEnabled = false
        pthread_mutex_lock(&_bufferInUseMutex)
        pthread_cond_signal(&_bufferFreeCondition)
        pthread_mutex_unlock(&_bufferInUseMutex)
        aq_log("enter")
        _mutex.lock()
        guard let queue = _outAQ else {
            _mutex.unlock()
            return
        }
        _mutex.unlock()
        if AudioQueueFlush(queue) != 0 {
            aq_log("AudioQueueFlush failed!")
        }
        
        if immediately {
            let this = Unmanaged.passUnretained(self).toOpaque()
            AudioQueueRemovePropertyListener(queue,
                                             kAudioQueueProperty_IsRunning,
                                             AudioQueue.audioQueueIsRunningCallback,
                                             this)
        }
        AudioQueueStop(queue, immediately).check(operation: "AudioQueueStop failed!")
        if immediately { state = .idle }
        aq_log("leave")
    }
    
    var state: State {
        get { return _state }
        set {
            _mutex.lock()
            if (_state == newValue) {
                _mutex.unlock()
                /* We are already in this state! */
                return
            }
            _state = newValue
            _mutex.unlock()
            delegate?.audioQueueStateChanged(state: state)
        }
    }
    
    func setPlayRate(playRate: Float) {
        var playRate = playRate
        let configuration = StreamConfiguration.shared
        
        if !configuration.enableTimeAndPitchConversion {
            #if (arch(i386) || arch(x86_64)) && os(iOS) //iPhone Simulator
                print("*** FreeStreamer notification: Trying to set play rate for audio queue but enableTimeAndPitchConversion is disabled from configuration. Play rate setting will not work.")
            #endif
            return
        }
        
        guard let queue = _outAQ else { return }
        if playRate < 0.5 { playRate = 0.5 }
        if playRate > 2.0 { playRate = 2.0 }
        AudioQueueSetParameter(queue, kAudioQueueParam_PlayRate, playRate)
    }
    
    var currentTime: AudioTimeStamp {
        var queueTime: AudioTimeStamp = AudioTimeStamp()
        if let queue = _outAQ {
            var discontinuity: DarwinBoolean  = false
            let err = AudioQueueGetCurrentTime(queue, nil, &queueTime, &discontinuity)
            if err != noErr {
                aq_log("AudioQueueGetCurrentTime failed")
            }
        }
        return queueTime
    }
    
    var levels: AudioQueueLevelMeterState {
        if !_levelMeteringEnabled, let queue = _outAQ {
            var enabledLevelMeter: Bool = true
            AudioQueueSetProperty(queue,
                                  kAudioQueueProperty_EnableLevelMetering,
                                  &enabledLevelMeter,
                                  UInt32(MemoryLayout<UInt32>.size))
            _levelMeteringEnabled = true
        }
        
        var levelMeter = AudioQueueLevelMeterState()
        if let queue = _outAQ {
            var levelMeterSize = UInt32(MemoryLayout<AudioQueueLevelMeterState>.size)
            AudioQueueGetProperty(queue, kAudioQueueProperty_CurrentLevelMeterDB, &levelMeter, &levelMeterSize)
        }
        return levelMeter
    }
    
    func handleAudioPackets(inNumberBytes: UInt32, inNumberPackets: UInt32, inInputData: UnsafeRawPointer, inPacketDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>) {
        if !initialized {
            aq_log("warning: attempt to handle audio packets with uninitialized audio queue. return.")
            return
        }
        // this is called by audio file stream when it finds packets of audio
//        aq_log("got data.  bytes: \(inNumberBytes)  packets: \(inNumberPackets)")
        /* Place each packet into a buffer and then send each buffer into the audio
         queue */
        let total = Int(inNumberPackets)
        for i in 0..<total {
            var desc = inPacketDescriptions.advanced(by: i).pointee
            
            
            if !initialized {
                aq_log("warning: attempt to handle audio packets with uninitialized audio queue. return.")
                return
            }
            
            let config = StreamConfiguration.shared
            
            let packetSize = desc.mDataByteSize
            let bufferSize = UInt32(config.bufferSize)
            let offset:Int = Int(desc.mStartOffset)
            
            
            /* This shouldn't happen because most of the time we read the packet buffer
             size from the file stream, but if we restored to guessing it we could
             come up too small here */
            if packetSize > bufferSize {
                aq_log("packetSize \(packetSize) > AQ_BUFSIZ \(bufferSize)")
                return
            }
            
            // if the space remaining in the buffer is not enough for this packet, then
            // enqueue the buffer and wait for another to become available.
            if (bufferSize - _bytesFilled < packetSize) {
                enqueueBuffer()
                if (!_audioQueueStarted) { return }
            } else {
                aq_log("skipped enqueueBuffer AQ_BUFSIZ - m_bytesFilled \(bufferSize) - \(_bytesFilled), packetSize \(packetSize)")
            }
            
            // copy data to the audio queue buffer
            if let buffer = _audioQueueBuffer?[Int(_fillBufferIndex)] {
                memcpy(buffer.pointee.mAudioData.advanced(by: Int(_bytesFilled)), inInputData.advanced(by: offset), Int(packetSize))
                desc.mStartOffset = Int64(_bytesFilled)
            }
            
            
            let index = Int(_packetsFilled)
            // fill out packet description to pass to enqueue() later on
            _packetDescs[index] = desc
            // Make sure the offset is relative to the start of the audio buffer
            _packetDescs[index].mStartOffset = Int64(_bytesFilled)
            // keep track of bytes filled and packets filled
            _bytesFilled += packetSize
            _packetsFilled += 1
            
            /* If filled our buffer with packets, then commit it to the system */
            if _packetsFilled >= UInt32(config.maxPacketDescs) { enqueueBuffer() }
        }
    }
    
    func reset(isSeeking: Bool = false) {
        guard var desc = streamDesc else {
            aq_log("streamDesc not validate!");
            return
        }
        cleanup()
        var err = noErr
        let this = UnsafeMutableRawPointer.voidPointer(from: self)
        err = AudioQueueNewOutput(&desc, AudioQueue.audioQueueOutputCallback, this, CFRunLoopGetCurrent(), nil, 0, &_outAQ)
        guard let queue = _outAQ else {
            if err != noErr {
                aq_log("error in AudioQueueNewOutput")
                lastError = err
            }
            delegate?.audioQueueInitializationFailed()
            return
        }
        
        guard let audioQueueBuffer = _audioQueueBuffer else {
            aq_log("_audioQueueBuffer not validate")
            return
        }
        
        // allocate audio queue buffers
        let configuration = StreamConfiguration.shared
        let bufferCount = Int(configuration.bufferCount)
        for i in 0..<bufferCount {
            let buffer = audioQueueBuffer.advanced(by: i)
            err = AudioQueueAllocateBuffer(queue, UInt32(configuration.bufferSize), buffer)
            if err != noErr {
                /* If allocating the buffers failed, everything else will fail, too.
                 *  Dispose the queue so that we can later on detect that this
                 *  queue in fact has not been initialized.
                 */
                aq_log(" error in AudioQueueAllocateBuffer")
                AudioQueueDispose(queue, true)
                _outAQ = nil
                lastError = err
                delegate?.audioQueueInitializationFailed()
                return
            }
        }
        
        // listen for kAudioQueueProperty_IsRunning
        err = AudioQueueAddPropertyListener(queue, kAudioQueueProperty_IsRunning, AudioQueue.audioQueueIsRunningCallback, this)
        if err != lastError {
            aq_log("error in AudioQueueAddPropertyListener")
            lastError = err
            return
        }
        if configuration.enableTimeAndPitchConversion {
            var enableTimePitchConversion = UInt32(1)
            err = AudioQueueSetProperty (queue, kAudioQueueProperty_EnableTimePitch, &enableTimePitchConversion, UInt32(MemoryLayout<UInt32>.size))
            if err != noErr {
                aq_log("Failed to enable time and pitch conversion. Play rate setting will fail")
            }
        }
        if isSeeking {
            volume = 0
        } else if initialOutputVolume != 1.0 {
            volume = initialOutputVolume
        }
    }
}

// MARK: - Private
extension AudioQueue {
    
    private func cleanup() {
        
        _mutex.lock()
        guard let queue = _outAQ else {
            _mutex.unlock()
            aq_log("warning: attempt to cleanup an uninitialized audio queue. return.")
            return
        }
        _mutex.unlock()
        let config = StreamConfiguration.shared
        let cstate = currentState
        if cstate != .idle {
            aq_log("attemping to cleanup the audio queue when it is still playing, force stopping")
            let this = Unmanaged.passRetained(self).toOpaque()
            AudioQueueRemovePropertyListener(queue, kAudioQueueProperty_IsRunning, AudioQueue.audioQueueIsRunningCallback, this)
            AudioQueueStop(queue, true)
            state = .idle
        }
        _mutex.lock()
        if (AudioQueueDispose(queue, true) != 0) { aq_log("AudioQueueDispose failed!"); }
        _outAQ = nil
        _mutex.unlock()
        _fillBufferIndex = 0
        _bytesFilled = 0
        _packetsFilled = 0
        _buffersUsed = 0
        
        let bufferCount = Int(config.bufferCount)
        for i in 0..<bufferCount { _bufferInUse?.advanced(by: i).pointee = false }
        lastError = noErr
    }
    
    private func enqueueBuffer() {
        guard let queue = _outAQ else { return }
        let index = Int(_fillBufferIndex)
        aq_assert(_bufferInUse?[index] == false)
        
        let config = StreamConfiguration.shared
        
//        aq_log("enter")
        
        pthread_mutex_lock(&_bufferInUseMutex)
        
        _bufferInUse?[index] = true
        _buffersUsed += 1
        
        // enqueue buffer
        guard let fillBuf = _audioQueueBuffer?[index] else { return }
        fillBuf.pointee.mAudioDataByteSize = _bytesFilled

        pthread_mutex_unlock(&_bufferInUseMutex)
        
        aq_assert(_packetsFilled > 0)
        
        let err = AudioQueueEnqueueBuffer(queue, fillBuf, _packetsFilled, &_packetDescs)
        
        if err == noErr {
            lastError = noErr
            start()
        } else {
            /* If we get an error here, it very likely means that the audio queue is no longer
             running */
            aq_log("error in AudioQueueEnqueueBuffer")
            lastError = err
            return
        }
        
        pthread_mutex_lock(&_bufferInUseMutex)
        // go to next buffer
        _fillBufferIndex += 1
        if _fillBufferIndex >= UInt32(config.bufferCount) {
            _fillBufferIndex = 0
        }
        // reset bytes filled
        _bytesFilled = 0
        // reset packets filled
        _packetsFilled = 0
        
        // wait until next buffer is not in use
        while (_bufferInUse?[Int(_fillBufferIndex)] == true) {
//            aq_log("waiting for buffer \(_fillBufferIndex)")
            pthread_cond_wait(&_bufferFreeCondition, &_bufferInUseMutex)
        }
        pthread_mutex_unlock(&_bufferInUseMutex)
    }
}

// MARK: - Call back
extension AudioQueue {
    // MARK: CallBacks
    private static var audioQueueIsRunningCallback: AudioQueuePropertyListenerProc {
        return { inClientData, inAQ, inID in
            guard let audioQueue = inClientData?.to(object: AudioQueue.self) else { return }
            aq_log("enter")
            var running = UInt32()
            var output = UInt32(MemoryLayout<UInt32>.size)
            let err = AudioQueueGetProperty(inAQ, kAudioQueueProperty_IsRunning, &running, &output)
            if err != noErr {
                aq_log("error in kAudioQueueProperty_IsRunning")
                return
            }
            if running != 0 {
                aq_log("audio queue running!")
                audioQueue.state = .running
            } else {
                audioQueue.state = .idle
            }
        }
    }
    
    // this is called by the audio queue when it has finished decoding our data.
    // The buffer is now free to be reused.
    private static var audioQueueOutputCallback: AudioQueueOutputCallback {
        return { (inClientData, inAQ, inBuffer) in
            guard let audioQueue = inClientData?.to(object: AudioQueue.self), let audioQueueBuffer = audioQueue._audioQueueBuffer else { return }
            
            let config = StreamConfiguration.shared
            let bufferCount = Int(config.bufferCount)
            var bufIndex = -1
            for i in 0..<bufferCount {
                guard let buffer = audioQueueBuffer.advanced(by: i).pointee else { continue }
                if buffer == inBuffer {
                    bufIndex = i
                    break
                }
            }
            if bufIndex == -1 { return }
            pthread_mutex_lock(&audioQueue._bufferInUseMutex)
            aq_assert(audioQueue._bufferInUse?[bufIndex] == true)
            
            audioQueue._bufferInUse?[bufIndex] = false
            audioQueue._buffersUsed -= 1
//            aq_log("signaling buffer free for inuse \(bufIndex)....")
            pthread_cond_signal(&audioQueue._bufferFreeCondition)
//            aq_log("signal sent!")
            if audioQueue._buffersUsed == 0 {
//                aq_log("audioQueueOutputCallback: unlock 2")
                pthread_mutex_unlock(&audioQueue._bufferInUseMutex)
                audioQueue.delegate?.audioQueueBuffersEmpty()
            } else {
                pthread_mutex_unlock(&audioQueue._bufferInUseMutex)
                audioQueue.delegate?.audioQueueFinishedPlayingPacket()
            }
//            aq_log("audioQueueOutputCallback: unlock")
        }
    }
}
