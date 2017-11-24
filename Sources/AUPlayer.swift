//
//  AUPlayer.swift
//  VinylPlayer
//
//  Created by lincolnlaw on 2017/9/1.
//  Copyright © 2017年 lincolnlaw. All rights reserved.
//

import Foundation
import AudioUnit
#if os(iOS)
    import UIKit
    import AVFoundation
#endif

public final class AUPlayer {
    
    private var _provider: StreamProvider?
    private lazy var _stream: AudioStream? = nil//AudioStream()

    private lazy var _converterNodes: [AUNode] = []
    private lazy var _volume: Float = 1
    
    private var _audioGraph: AUGraph?
    
    private var _equalizerEnabled = false
    private var _equalizerOn = false
    
    private var usedSize: Int = 0
    
    private var maxSizeForNextRead = 0
    private var _cachedSize = 0
    
    private lazy var _eqNode: AUNode = 0
    private lazy var _mixerNode: AUNode = 0
    private lazy var _outputNode: AUNode = 0
    
    private lazy var _eqInputNode: AUNode = 0
    private lazy var _eqOutputNode: AUNode = 0
    private lazy var _mixerInputNode: AUNode = 0
    private lazy var _mixerOutputNode: AUNode = 0
    
    private var _eqUnit: AudioComponentInstance?
    private var _mixerUnit: AudioComponentInstance?
    private var _outputUnit: AudioComponentInstance?
    
    private var _audioConverterRef: AudioConverterRef?
    private var _audioConverterAudioStreamBasicDescription: AudioStreamBasicDescription = AudioStreamBasicDescription()
    
    private lazy var _eqBandCount: UInt32 = 0
    
    private var state: State {
        get { return _stateQueue.sync { return _state } }
        set {
            _stateQueue.sync { _state = newValue }
            _stream?.audioQueueStateChanged(state: newValue)
        }
    }
    private var _state: State = .idle
    private lazy var _seekToTimeWasRequested: Bool = false
    
    private lazy var _stateQueue = DispatchQueue(label: "VinylPlayer.AUPlayer.stateQueue")
    
 
    private let _pcmBufferFrameSizeInBytes: UInt32 = AUPlayer.canonical.mBytesPerFrame
    
    private var _progress: Double = 0
 
    #if os(iOS)
    private lazy var _backgroundTask = UIBackgroundTaskInvalid
    #endif
    
    private lazy var _currentIndex = 0
    private lazy var _pageSize = AUPlayer.maxReadPerSlice
    private func increaseBufferIndex() {
        _stateQueue.sync {
            _currentIndex = (_currentIndex + 1) % Int(AUPlayer.minimumBufferCount)
        }
    }
    private lazy var _buffers: UnsafeMutablePointer<UInt8> = {
        let size = AUPlayer.minimumBufferSize
        let b = malloc(size).assumingMemoryBound(to: UInt8.self)
        b.initialize(to: 0, count: size)
        return b
    }()
    
    deinit {
        let size = AUPlayer.minimumBufferSize
        _buffers.deinitialize(count: size)
        _buffers.deallocate(capacity: size)
    }
    
    public init() {
        createAudioGraph()
    }
    
    public func play(url: URL) {
        _provider = StreamProvider(url: url)
        _provider?.autoProduce = false
        _provider?.open()
        resume()
    }
}


// MARK: - Open API
extension AUPlayer {
    
    func pause() {
        guard let audioGraph = _audioGraph else { return }
        if AUGraphStop(audioGraph) != noErr {
            _stream?.audioQueueInitializationFailed()
            return
        }
        state = .paused
        #if os(iOS)
            NowPlayingInfo.shared.pause(elapsedPlayback: currentTime())
        #endif
    }
    
    func resume() {
        
        guard let graph = _audioGraph else { return }
        if state == .paused {
            state = .running
            guard let audioGraph = _audioGraph  else { return }
            if AUGraphStart(audioGraph) != noErr {
                _stream?.audioQueueInitializationFailed()
                return
            }
        } else if state == .idle {
            _progress = 0
            if audioGraphIsRunning() { return }
            do {
                try AUGraphStart(graph).throwCheck()
                startBackgroundTask()
                state = .running
            } catch {
                
            }
        }
        #if os(iOS)
            NowPlayingInfo.shared.play(elapsedPlayback: currentTime())
        #endif
        
    }
    
    func currentTime() -> Double {
        return _progress
    }
    
    func togglePlayPause() {
        _state == .paused ? resume() : pause()
    }
    
    func next() { }
    
    func previous() { }
    
    func seek(to time: Float) { }
    
    func setVolume(value: Float) {
        _volume = value
        #if os(iOS)
            if let unit = _mixerUnit {
                AudioUnitSetParameter(unit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, value, 0)
            }
        #else
            if let unit = _mixerUnit {
                AudioUnitSetParameter(unit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, value, 0)
            } else if let unit = _outputUnit {
                AudioUnitSetParameter(unit, kHALOutputParam_Volume, kAudioUnitScope_Output, AUPlayer.Bus.output, value, 0)
            }
        #endif
    }
}

// MARK: - Create
private extension AUPlayer {
    // MARK: createAudioGraph
    func createAudioGraph() {
        do {
            try NewAUGraph(&_audioGraph).throwCheck()
            guard let graph = _audioGraph else { return }
            try AUGraphOpen(graph).throwCheck()
            createEqUnit()
            createMixerUnit()
            createOutputUnit()
            connectGraph()
            try AUGraphInitialize(graph).throwCheck()
            setVolume(value: 1)
        } catch {
            _stream?.audioQueueInitializationFailed()
        }
    }
    
    
    private func createEqUnit() {
        #if os(OSX)
            guard #available(OSX 10.9, *) else { return }
        #endif
        let _options = StreamConfiguration.shared
        guard let value = _options.equalizerBandFrequencies[fp_safe: 0], value != 0, let audioGraph = _audioGraph else { return }
        do {
            try AUGraphAddNode(audioGraph, &AUPlayer.nbandUnit, &_eqNode).throwCheck()
            try AUGraphNodeInfo(audioGraph, _eqNode, nil, &_eqUnit).throwCheck()
            guard let eqUnit = _eqUnit else { return }
            let size = MemoryLayout.size(ofValue: AUPlayer.maxFramesPerSlice)
            try AudioUnitSetProperty(eqUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &AUPlayer.maxFramesPerSlice, UInt32(size)).throwCheck()
            while _options.equalizerBandFrequencies[fp_safe: Int(_eqBandCount)] != nil {
                _eqBandCount += 1
            }
            let eqBandSize = UInt32(MemoryLayout.size(ofValue: _eqBandCount))
            try AudioUnitSetProperty(eqUnit, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &_eqBandCount, eqBandSize).throwCheck()
            for i in 0..<_eqBandCount {
                let value = _options.equalizerBandFrequencies[Int(i)]
                try AudioUnitSetParameter(eqUnit, kAUNBandEQParam_Frequency + i, kAudioUnitScope_Global, 0, value, 0).throwCheck()
            }
            
            for i in 0..<_eqBandCount {
                try AudioUnitSetParameter(eqUnit, kAUNBandEQParam_BypassBand + i, kAudioUnitScope_Global, 0, 0, 0).throwCheck()
            }
        } catch { _stream?.audioQueueInitializationFailed() }
    }
    
    private func createMixerUnit() {
        let _options = StreamConfiguration.shared
        guard _options.enableVolumeMixer, let graph = _audioGraph else { return }
        do {
            try AUGraphAddNode(graph, &AUPlayer.mixer, &_mixerNode).throwCheck()
            try AUGraphNodeInfo(graph, _mixerNode, &AUPlayer.mixer, &_mixerUnit).throwCheck()
            guard let mixerUnit = _mixerUnit else { return }
            let size = UInt32(MemoryLayout.size(ofValue: AUPlayer.maxFramesPerSlice))
            try AudioUnitSetProperty(mixerUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &AUPlayer.maxFramesPerSlice, size).throwCheck()
            var busCount: UInt32 = 1
            let busCountSize = UInt32(MemoryLayout.size(ofValue: busCount))
            try AudioUnitSetProperty(mixerUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, busCountSize).throwCheck()
            var graphSampleRate: Float64 = 44100
            let graphSampleRateSize = UInt32(MemoryLayout.size(ofValue: graphSampleRate))
            try AudioUnitSetProperty(mixerUnit, kAudioUnitProperty_SampleRate, kAudioUnitScope_Output, 0, &graphSampleRate, graphSampleRateSize).throwCheck()
            try AudioUnitSetParameter(mixerUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, 0, 1, 0).throwCheck()
        } catch { _stream?.audioQueueInitializationFailed() }
    }
    
    private func createOutputUnit() {
        guard let audioGraph = _audioGraph else { return }
        do {
            try AUGraphAddNode(audioGraph, &AUPlayer.outputUnit, &_outputNode).throwCheck()
            try AUGraphNodeInfo(audioGraph, _outputNode, &AUPlayer.outputUnit, &_outputUnit).throwCheck()
            guard let unit = _outputUnit else { return }
            #if !os(OSX)
                var flag: UInt32 = 1
                let size = UInt32(MemoryLayout.size(ofValue: flag))
                try AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, AUPlayer.Bus.output, &flag, size).throwCheck()
                flag = 0
                try AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, AUPlayer.Bus.input, &flag, size).throwCheck()
            #endif
            let s = MemoryLayout.size(ofValue: AUPlayer.canonical)
            try AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, AUPlayer.Bus.output, &AUPlayer.canonical, UInt32(s)).throwCheck()
        } catch { _stream?.audioQueueInitializationFailed() }
    }
    
    private func connectGraph() {
        guard let audioGraph = _audioGraph else { return }
        AUGraphClearConnections(audioGraph)
        for node in _converterNodes {
            AUGraphRemoveNode(audioGraph, node).check()
        }
        _converterNodes.removeAll()
        var nodes: [AUNode] = []
        var units: [AudioComponentInstance] = []
        if let unit = _eqUnit {
            if _equalizerEnabled {
                nodes.append(_eqNode)
                units.append(unit)
                _equalizerOn = true
            } else {
                _equalizerOn = false
            }
        } else {
            _equalizerOn = false
        }
        
        if let unit = _mixerUnit {
            nodes.append(_mixerNode)
            units.append(unit)
        }
        
        if let unit = _outputUnit {
            nodes.append(_outputNode)
            units.append(unit)
        }
        if let node = nodes.first, let unit = units.first {
            setOutputCallback(for: node, unit: unit)
        }
        for i in 0..<nodes.count-1 {
            let node = nodes[i]
            let nextNode = nodes[i+1]
            let unit = units[i]
            let nextUnit = units[i+1]
            connect(node: node, destNode: nextNode, unit: unit, destUnit: nextUnit)
        }
    }
    
    func setOutputCallback(for node: AUNode, unit: AudioComponentInstance) {
        var status: OSStatus = noErr
        let callback: AURenderCallback = { (userInfo, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioBufferList) -> OSStatus in
            let sself = userInfo.to(object: AUPlayer.self)
            return sself.outputRenderCallback(ioActionFlags: ioActionFlags, inTimeStamp: inTimeStamp, inBusNumber: inBusNumber, inNumberFrames: inNumberFrames, ioData: ioBufferList)
        }
        let pointer = UnsafeMutableRawPointer.from(object: self)
        var callbackStruct = AURenderCallbackStruct(inputProc: callback, inputProcRefCon: pointer)
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &AUPlayer.canonical, AUPlayer.canonicalSize)
        guard let audioGraph = _audioGraph else { return }
        do {
            if status == noErr {
                try AUGraphSetNodeInputCallback(audioGraph, node, 0, &callbackStruct).throwCheck()
            } else {
                var format: AudioStreamBasicDescription = AudioStreamBasicDescription()
                var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                try AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, &size).throwCheck()
                let converterNode = createConverterNode(for: AUPlayer.canonical, destFormat: format)
                guard let c = converterNode  else { return }
                try AUGraphSetNodeInputCallback(audioGraph, c, 0, &callbackStruct).throwCheck()
                try AUGraphConnectNodeInput(audioGraph, c, 0, node, 0).throwCheck()
            }
        } catch { _stream?.audioQueueInitializationFailed() }
    }
    
    func connect(node: AUNode, destNode: AUNode, unit: AudioComponentInstance, destUnit: AudioComponentInstance) {
        guard let audioGraph = _audioGraph else { return }
        var status: OSStatus = noErr
        var needConverter = false
        var srcFormat: AudioStreamBasicDescription = AudioStreamBasicDescription()
        var desFormat: AudioStreamBasicDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        do {
            try AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &srcFormat, &size).throwCheck()
            try AudioUnitGetProperty(destUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &desFormat, &size).throwCheck()
            
            needConverter = memcmp(&srcFormat, &desFormat, MemoryLayout.size(ofValue: srcFormat)) != 0
            if needConverter {
                status = AudioUnitSetProperty(destUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &srcFormat, UInt32(MemoryLayout.size(ofValue: srcFormat)))
                needConverter = status != noErr
            }
            if needConverter {
                if let convertNode = createConverterNode(for: srcFormat, destFormat: desFormat){
                    try AUGraphConnectNodeInput(audioGraph, node, 0, convertNode, 0).throwCheck()
                    try AUGraphConnectNodeInput(audioGraph, convertNode, 0, destNode, 0).throwCheck()
                }
                
            } else {
                try AUGraphConnectNodeInput(audioGraph, node, 0, destNode, 0).throwCheck()
            }
        } catch { _stream?.audioQueueInitializationFailed()  }
    }
    
    func createConverterNode(for format: AudioStreamBasicDescription, destFormat: AudioStreamBasicDescription) -> AUNode? {
        guard let audioGraph = _audioGraph else { return nil }
        var convertNode = AUNode()
        var convertUnit: AudioComponentInstance?
        do {
            try AUGraphAddNode(audioGraph, &AUPlayer.convertUnit, &convertNode).throwCheck()
            try AUGraphNodeInfo(audioGraph, convertNode, &AUPlayer.mixer, &convertUnit).throwCheck()
            guard let unit = convertUnit else { return nil }
            var srcFormat = format
            try AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &srcFormat, UInt32(MemoryLayout.size(ofValue: format))).throwCheck()
            var desFormat = destFormat
            try AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &desFormat, UInt32(MemoryLayout.size(ofValue: destFormat))).throwCheck()
            try AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &AUPlayer.maxFramesPerSlice, UInt32(MemoryLayout.size(ofValue: AUPlayer.maxFramesPerSlice))).throwCheck()
            _converterNodes.append(convertNode)
            return convertNode
        } catch {
            _stream?.audioQueueInitializationFailed()
            return nil
        }
    }
    
    private func audioGraphIsRunning() -> Bool {
        guard let graph = _audioGraph else { return false }
        var isRuning: DarwinBoolean = false
        guard AUGraphIsRunning(graph, &isRuning) == noErr else { return false }
        return isRuning.boolValue
    }
    
    @discardableResult private func startAudioGraph() -> Bool {
        guard let graph = _audioGraph else { return false }
        _progress = 0
        if audioGraphIsRunning() { return false }
        do {
            try AUGraphStart(graph).throwCheck()
            startBackgroundTask()
            state = .running
            return true
        } catch {
            _stream?.audioQueueInitializationFailed()
            return false
        }
    }
    
    private func endBackgroundTask() {
        #if os(iOS)
            guard _backgroundTask != UIBackgroundTaskInvalid else { return }
            UIApplication.shared.endBackgroundTask(_backgroundTask)
            _backgroundTask = UIBackgroundTaskInvalid
        #endif
    }
    
    private func startBackgroundTask() {
        #if os(iOS)
            if StreamConfiguration.shared.automaticAudioSessionHandlingEnabled {
                do {
                    try AVAudioSession.sharedInstance().setCategory(AVAudioSessionCategoryPlayback)
                    try AVAudioSession.sharedInstance().setActive(true)
                } catch {
                    print("error:\(error)")
                }
            }
            endBackgroundTask()
            _backgroundTask = UIApplication.shared.beginBackgroundTask(expirationHandler: {[weak self] in
                self?.endBackgroundTask()
            })
        #endif
    }
    
    private func outputRenderCallback(ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, inTimeStamp: UnsafePointer<AudioTimeStamp>, inBusNumber: UInt32, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        let size = _pcmBufferFrameSizeInBytes * inNumberFrames
        ioData?.pointee.mBuffers.mNumberChannels = 2
        ioData?.pointee.mBuffers.mDataByteSize = size
        let raw = _buffers.advanced(by: _currentIndex * _pageSize)
        increaseBufferIndex()
        let readSize = UInt32(_provider!.read(bytes: raw, count: UInt(size)))
        var totalReadFrame: UInt32 = inNumberFrames
        if readSize == 0 {
            if _progress >= 1 {
                pause()
            } else {
                _stream?.audioQueueBuffersEmpty()
                ioActionFlags.pointee = AudioUnitRenderActionFlags.unitRenderAction_OutputIsSilence
            }
            memset(raw, 0, Int(size))
            return noErr
        } else if readSize != size {
            totalReadFrame = readSize / _pcmBufferFrameSizeInBytes
            let left = size - readSize
            memset(raw.advanced(by: Int(readSize)), 0, Int(left))
        }
        usedSize += Int(readSize)
        ioData?.pointee.mBuffers.mData = UnsafeMutableRawPointer(raw)
        _progress += Double(totalReadFrame) / AUPlayer.canonical.mSampleRate
        _stream?.audioQueueFinishedPlayingPacket()
        return noErr
    }
}

extension AUPlayer {

    struct Bus {
        static let output: UInt32 = 0
        static let input: UInt32 = 1
    }
    
    static var maxFramesPerSlice: UInt32 = 4096
    static let maxReadPerSlice: Int = Int(maxFramesPerSlice * canonical.mBytesPerPacket)
    static let minimumBufferCount: Int = 8
    static let minimumBufferSize: Int = maxReadPerSlice * minimumBufferCount
    
    
    static var outputUnit: AudioComponentDescription = {
        #if os(OSX)
            let subType = kAudioUnitSubType_DefaultOutput
        #else
            let subType = kAudioUnitSubType_RemoteIO
        #endif
        let component = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: subType, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        return component
    }()
    
    static var canonical: AudioStreamBasicDescription = {
        var bytesPerSample = UInt32(MemoryLayout<Int32>.size)
        if #available(iOS 8.0, *) {
            bytesPerSample = UInt32(MemoryLayout<Int16>.size)
        }
        let flags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
        let component = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags, mBytesPerPacket: bytesPerSample * 2, mFramesPerPacket: 1, mBytesPerFrame: bytesPerSample * 2, mChannelsPerFrame: 2, mBitsPerChannel: 8 * bytesPerSample, mReserved: 0)
        return component
    }()
    
    static var canonicalSize: UInt32 = {
        return UInt32(MemoryLayout.size(ofValue: canonical))
    }()
    
    static var convertUnit: AudioComponentDescription = {
        let component = AudioComponentDescription(componentType: kAudioUnitType_FormatConverter, componentSubType: kAudioUnitSubType_AUConverter, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        return component
    }()
    static var mixer: AudioComponentDescription = {
        let component = AudioComponentDescription(componentType: kAudioUnitType_Mixer, componentSubType: kAudioUnitSubType_MultiChannelMixer, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        return component
    }()
    
    static func record() -> AudioStreamBasicDescription {
        var component = AudioStreamBasicDescription()
        component.mFormatID = kAudioFormatMPEG4AAC
        component.mFormatFlags = AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue)
        component.mChannelsPerFrame = canonical.mChannelsPerFrame
        component.mSampleRate = canonical.mSampleRate
        return component
    }
    
    static var nbandUnit: AudioComponentDescription = {
        let component = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_NBandEQ, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        return component
    }()
}



