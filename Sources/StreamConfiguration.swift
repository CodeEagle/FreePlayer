//
//  StreamConfiguration.swift
//  FreePlayer
//
//  Created by Lincoln Law on 2017/2/19.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//

import AudioToolbox
import AVFoundation
#if os(iOS)
    import UIKit
#endif
public var FreePlayerVersion: Double = 1.1
/** FreePlayer 配置单例 */
/**
 # 因为 StreamConfiguration.shared 是 struct
 # 所以，不能这样赋值（会触发 copy on write）
     var shared = StreamConfiguration.shared  
     shared.xxx = xxx
 */
public struct StreamConfiguration {
    
    public enum AuthenticationScheme {
        
        case digest, basic
        
        var name: CFString {
            switch self {
            case .digest: return kCFHTTPAuthenticationSchemeDigest
            case .basic: return kCFHTTPAuthenticationSchemeBasic
            }
        }
    }
    
    public static var shared: StreamConfiguration = StreamConfiguration()
    /** 缓冲数 */
    public var bufferCount = UInt()
    /** 每个缓冲的大小 */
    public var bufferSize = UInt()
    /** 最大帧数 */
    public var maxPacketDescs = UInt()
    /** http 缓冲大小 */
    public var httpConnectionBufferSize = UInt()
    /** 转化为 PCM 的采样率 */
    public var outputSampleRate = Double()
    /** 转化为 PCM 声道数 */
    public var outputNumChannels = Int()
    ///
    public var bounceInterval = Int()
    /** 监控播放最大时长 ，超过时长则🚔*/
    public var startupWatchdogPeriod = Int()
    ///
    public var maxBounceCount = Int()
    /** 磁盘最大缓存数(bytes)*/
    public var maxDiskCacheSize = Int()
    /** 最大缓冲数(bytes) */
    public var maxPrebufferedByteCount = Int()
    /** 流媒体最低预缓冲数(bytes)*/
    public var requiredInitialPrebufferedByteCountForContinuousStream = Int()
    /** 非流媒体最低预缓冲数(bytes)*/
    public var requiredInitialPrebufferedByteCountForNonContinuousStream = Int()
    /** 最低预缓冲秒数 */
    public var requiredPrebufferSizeInSeconds = Int()
    /** 最低预缓冲帧数 */
    public var requiredInitialPrebufferedPacketCount = Int()
    /** 自定义 UA */
    public var userAgent: String?
    /** 缓存目录 */
    public var cacheDirectory = NSTemporaryDirectory()
    /** 存储目录 */
    public var storeDirectory: String? 
    /** 自定义 http header 字典 */
    public var predefinedHttpHeaderValues: [String : String] = [:]
    /** 使用时间数计算预缓冲大小 */
    public var usePrebufferSizeCalculationInSeconds = Bool()
    /** 使用帧数计算预缓冲大小 */
    public var usePrebufferSizeCalculationInPackets = Bool()
    /** 缓存播放文件 */
    public var cacheEnabled = false
    /** 使用缓存 seeking */
    public var seekingFromCacheEnabled = false
    /** 自动控制 AudioSession */
    public var automaticAudioSessionHandlingEnabled = false
    /** 开启 Time And Pitch Conversion */
    public var enableTimeAndPitchConversion = false
    /** 需要内容类型检查 */
    public var requireStrictContentTypeChecking = false
    /** 需要网络播放检查 */
    public var requireNetworkPermision = true
    /** 自动填充ID3的信息到 NowPlayingCenter */
    public var autoFillID3InfoToNowPlayingCenter = false
    /** 使用自定义代理 */
    public var usingCustomProxy = false { didSet { didConfigureProxy() } }
    /** 使用自定义代理 用户名*/
    public var customProxyUsername = ""
    /** 使用自定义代理 密码*/
    public var customProxyPassword = ""
    /** 使用自定义代理 Http Host */
    public var customProxyHttpHost = "" { didSet { didConfigureProxy() } }
    /** 使用自定义代理 Http Port */
    public var customProxyHttpPort = 0 { didSet { didConfigureProxy() } }
    /** 使用自定义代理 authenticationScheme, kCFHTTPAuthenticationSchemeBasic... */
    public var customProxyAuthenticationScheme: AuthenticationScheme = .digest { didSet { didConfigureProxy() } }
    
    private init() {
        #if (arch(i386) || arch(x86_64)) && os(iOS)//iPhone Simulator
            bufferCount = 8
            bufferSize = 32768
            debugPrint("Notice: FreePlayer running on simulator, low latency audio not available!")
        #else
            bufferCount = 64
            bufferSize = 8192
        #endif
        
        maxPacketDescs = 512
        httpConnectionBufferSize = 8192
        outputSampleRate = 44100
        outputNumChannels = 2
        bounceInterval = 10
        maxBounceCount = 4   // Max number of bufferings in bounceInterval seconds
        startupWatchdogPeriod = 30
        
        /* Adjust the max in-memory cache to 20 MB with newer 64 bit devices or 5 MB for 32 bit devices*/
        #if DEBUG
            maxPrebufferedByteCount = 1000000
        #else
            maxPrebufferedByteCount = (MemoryLayout<CGFloat>.size == 8) ? 20000000 : 5000000
        #endif
        
        cacheEnabled = true
        seekingFromCacheEnabled = false
        automaticAudioSessionHandlingEnabled = true
        enableTimeAndPitchConversion = false
        requireStrictContentTypeChecking = true
        maxDiskCacheSize = 256000000 // 256 MB
        usePrebufferSizeCalculationInSeconds = true
        usePrebufferSizeCalculationInPackets = false
        requiredInitialPrebufferedPacketCount = 32
        requiredPrebufferSizeInSeconds = 7
        // With dynamic calculation, these are actually the maximum sizes, the dynamic
        // calculation may lower the sizes based on the stream bitrate
        requiredInitialPrebufferedByteCountForContinuousStream = 256000
        requiredInitialPrebufferedByteCountForNonContinuousStream = 256000
        
        var osStr = ""
        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            let sampleRate = session.sampleRate
            if sampleRate > 0 { outputSampleRate = sampleRate }
            let channels = session.outputNumberOfChannels
            if channels > 0 { outputNumChannels = channels }
            let version = UIDevice.current.systemVersion
            osStr = "iOS \(version)"
        #elseif os(OSX)
            requiredPrebufferSizeInSeconds = 3
            // No need to be so concervative with the cache sizes
            maxPrebufferedByteCount = 16000000 // 16 MB
            osStr = "macOS"
        #endif
        userAgent = "FreePlayer/\(FreePlayerVersion) \(osStr)"
    }
    
    private func didConfigureProxy() {
        NowPlayingInfo.shared.updateProxy()
    }
}
