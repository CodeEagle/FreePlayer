//
//  ID3Parser.swift
//  FreePlayer
//
//  Created by Lincoln Law on 2017/3/5.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//

import Foundation
enum Metadata {
    case text(String)
    case data(Data)
}
protocol ID3ParserDelegate: class {
    func id3metaDataAvailable(metaData: [String : Metadata])
    func id3tagSizeAvailable(tag size: UInt32)
}
final class ID3Parser {

    enum MetaDataKey: String {
        case artist = "MPMediaItemPropertyArtist"
        case title = "MPMediaItemPropertyTitle"
        case cover = "CoverArt"
    }
    
    weak var delegate: ID3ParserDelegate?
    
    fileprivate var _state: State = .initial
    fileprivate var _tagData: Data = Data()
    fileprivate var _bytesReceived = UInt32()
    fileprivate var _tagSize = UInt32()
    fileprivate var _majorVersion = UInt8()
    fileprivate var _hasFooter = false
    fileprivate var _usesUnsynchronisation = false
    fileprivate var _usesExtendedHeader = false
    fileprivate var _title = ""
    fileprivate var _performer = ""
    fileprivate var _coverArt: Data?
    fileprivate var _lock: OSSpinLock = OS_SPINLOCK_INIT
    fileprivate var _parsing = false
    fileprivate var _lastData: Data?
    fileprivate var _queue = DispatchQueue(label: "com.selfstudio.freeplayer.idrparser")
    
    fileprivate var _thread: pthread_t?
    
    enum State {
        case initial
        case parseFrames
        case tagParsed
        case notID3V2
    }
    
    fileprivate struct ID3V1Length {
        static var header: Int { return 3 }
        static var title: Int  { return 30 }
        static var artist: Int  { return 30 }
        static var album: Int  { return 30 }
        static var year: Int  { return 4 }
        static var comment: Int  { return 30 }
        static var genre: Int  { return 4 }
    }
    init() { }
}

extension ID3Parser {
    func setState(state: State) { _state = state }
    
    func parseContent(framesize: UInt32, pos: UInt32, encoding: CFStringEncoding, byteOrderMark: Bool) -> String {
        func un(raw: UnsafeMutablePointer<UInt8>) -> UnsafeMutablePointer<UInt8> { return raw }
        let pointer = _tagData.withUnsafeMutableBytes({ (item: UnsafeMutablePointer<UInt8>) in
            return item
        }).advanced(by: Int(pos))
        let size = framesize - 1
        return CFStringCreateWithBytes(kCFAllocatorDefault, pointer, Int(size), encoding, byteOrderMark)  as String
    }
}

extension ID3Parser {
    
    func reset() {
        _state = .initial
        _bytesReceived = 0
        _tagSize = 0
        _majorVersion = 0
        _hasFooter = false
        _usesUnsynchronisation = false
        _usesExtendedHeader = false
        _tagData.removeAll()
    }
    
    func wantData() -> Bool {
        let done = [State.tagParsed].contains(_state)
        return done == false
    }
    
    func feedData(data: UnsafeMutablePointer<UInt8>, numBytes: UInt32) {
        _queue.sync {
            if self.wantData() == false  { return }
            if  self._state == .tagParsed  { return }
            if self._parsing { return }
            self._bytesReceived += numBytes
//            id3_log("received \(numBytes) bytes, total bytesReceived \(self._bytesReceived)")
            let dat = Data(bytes: data, count: Int(numBytes))
            _lastData = dat
            if self._state != .notID3V2 {
                self._tagData.append(dat)
            }
            var canParseFrames = false
            if self._state == .initial {
                canParseFrames = self.initial()
            } else if self._state == .parseFrames {
                canParseFrames = true
            } else if self._state == .notID3V2 {
                var realData = dat
                var len = dat.count
                if len < 128 , let d = _lastData {
                    id3_log("append last data")
                    realData = d + dat
                    len = realData.count
                }
                if len < 128 {
                    id3_log("try parser id3v1 but len:\(len) to short")
                    return
                }
                let start = len - 128
                let v1 = realData[start..<len]
                let tag = v1.map({$0})[0..<3]
                let raw = String(bytes: tag, encoding: .ascii)
                if raw == "TAG" {
                    self.dealV1(with: v1.map({$0}))
                }
            }
            if canParseFrames, self._parsing == false {
                DispatchQueue.global(qos: .userInitiated).async {
                    self.parseFrames()
                }
            }
        }
    }
    
    private func dealV1(with data: [UInt8]) {
        _tagSize = 128
        id3_log("tag size: \(_tagSize)")
        if StreamConfiguration.shared.autoFillID3InfoToNowPlayingCenter == false { return }
        delegate?.id3tagSizeAvailable(tag: _tagSize)
        let total = [ID3V1Length.header, ID3V1Length.title, ID3V1Length.artist, ID3V1Length.album, ID3V1Length.year, ID3V1Length.comment]
        var offset = 0
        var end = 0
        for (i, len) in total.enumerated() {
            if i == 0 {
                offset += len
                continue
            }
            end = len + offset
            let t = offset..<end
            let range = data[t].flatMap({$0})
            let value = String(bytes: range, encoding: .ascii)?.replacingOccurrences(of: "\0", with: "") ?? ""
            switch i {
            case 1: _title = value
            case 2: _performer = value
            default: break
            }
            offset += len
        }
        DispatchQueue.main.async {
            self.setState(state: .tagParsed)
            self._tagData.removeAll()
            self._parsing = false
        }
        // Push out the metadata
        if let d = delegate {
            var metadataMap = [String : Metadata]()
            if !_performer.isEmpty {
                metadataMap[MetaDataKey.artist.rawValue] = Metadata.text(_performer)
            }
            if !_title.isEmpty {
                metadataMap[MetaDataKey.title.rawValue] = Metadata.text(_title)
            }
            if metadataMap.count > 0 {
                DispatchQueue.main.async { d.id3metaDataAvailable(metaData: metadataMap) }
            }
        }
    }
    
    private func initial() -> Bool {
        // Do we have enough bytes to determine if this is an ID3 tag or not?
        /*
         char Header[3]; /*必须为"ID3"否则认为标签不存在*/
         char Ver; /*版本号;ID3V2.3就记录03,ID3V2.4就记录04*/
         char Revision; /*副版本号;此版本记录为00*/
         char Flag; /*存放标志的字节，这个版本只定义了三位，稍后详细解说*/
         char Size[4]; /*标签大小，包括标签帧和标签头。（不包括扩展标签头的10个字节）*/
         */
        if _bytesReceived <= 9 { return false }
        let sub = _tagData[0...2]
        let content = String(bytes: sub, encoding: .ascii)
        if content != "ID3" {
            id3_log("Not an ID3v2 tag, bailing out")
            setState(state: .notID3V2)
            return false
        }
        _majorVersion = _tagData[3]
        // Currently support only id3v2.2 and 2.3
        if _majorVersion != 2 && _majorVersion != 3 && _majorVersion != 4 {
            id3_log("ID3v2.\(_majorVersion) not supported by the parser")
            setState(state: .notID3V2)
            return false
        }
        // Ignore the revision
        // Parse the flags
        if _tagData[5] & 0x80 != 0 {
            _usesUnsynchronisation = true
        } else if _tagData[5] & 0x40 != 0, _majorVersion >= 3 {
            _usesExtendedHeader = true
        } else if _tagData[5] & 0x10 != 0, _majorVersion >= 3 {
            _hasFooter = true
        }
        let six = (UInt32(_tagData[6]) & 0x7F) << 21
        let seven = (UInt32(_tagData[7]) & 0x7F) << 14
        let eight = (UInt32(_tagData[8]) & 0x7F) << 7
        let nine = UInt32(_tagData[9]) & 0x7F
        _tagSize = six | seven | eight | nine
        
        if _tagSize > 0 {
            if _hasFooter { _tagSize += 10 }
            _tagSize += 10
            id3_log("tag size: \(_tagSize)")
            delegate?.id3tagSizeAvailable(tag: _tagSize)
            if StreamConfiguration.shared.autoFillID3InfoToNowPlayingCenter == false {
                setState(state: .tagParsed)
                return false
            } else {
                setState(state: .parseFrames)
                return true
            }
        }
        setState(state: .notID3V2)
        return false
    }
    
    private func parseFrames() {
        // Do we have enough data to parse the frames?
        if _tagData.count < Int(_tagSize) {
            id3_log("Not enough data received for parsing, have \(_tagData.count) bytes, need \(_tagSize) bytes")
            DispatchQueue.main.async {
                self._parsing = false
            }
            return
        }
        _parsing = true
        var pos = 10
        // Do we have an extended header? If we do, skip it
        if _usesExtendedHeader {
            let i = UInt32(_tagData[pos])
            let ii = UInt32(_tagData[pos+1])
            let iii = UInt32(_tagData[pos+2])
            let iv = UInt32(_tagData[pos+3])
            let extendedHeaderSize = Int((i << 21) | (ii << 14) | (iii << 7) | iv)
            
            if pos + extendedHeaderSize >= Int(_tagSize) {
                DispatchQueue.main.async {
                    self.setState(state: .notID3V2)
                    self._parsing = false
                }
                return
            }
            id3_log("Skipping extended header, size \(extendedHeaderSize)")
            pos += extendedHeaderSize
        }
        
        while pos < Int(_tagSize) {
            var frameName: [UInt8] = Array(repeatElement(0, count: 4))
            frameName[0] = _tagData[pos]
            frameName[1] = _tagData[pos+1]
            frameName[2] = _tagData[pos+2]
            
            if _majorVersion >= 3 { frameName[3] = _tagData[pos+3] }
            else { frameName[3] = 0 }
            
            var framesize = 0
            var i: UInt32
            var ii: UInt32
            var iii: UInt32
            var iv: UInt32
            if _majorVersion >= 3 {
                pos += 4
                i = UInt32(_tagData[pos])
                ii = UInt32(_tagData[pos+1])
                iii = UInt32(_tagData[pos+2])
                iv = UInt32(_tagData[pos+3])
                framesize = Int((i << 21) + (ii << 14) + (iii << 7) + iv)
            } else {
                i = UInt32(_tagData[pos])
                ii = UInt32(_tagData[pos+1])
                iii = UInt32(_tagData[pos+2])
                iv = 0
                framesize = Int((i << 16) + (ii << 8) + iii)
            }
            
            if framesize == 0 {
                DispatchQueue.main.async {
                    self.setState(state: .notID3V2)
                    self._parsing = false
                }
                break
                // Break from the loop and then out of the case context
            }
            
            if _majorVersion >= 3 { pos += 6 }
            else { pos += 3 }
            
            // ISO-8859-1 is the default encoding
            var encoding = CFStringBuiltInEncodings.isoLatin1.rawValue
            var byteOrderMark = false
            
            if _tagData[pos] == 3 {
                encoding = CFStringBuiltInEncodings.UTF8.rawValue
            } else if _tagData[pos] == 2 {
                encoding = CFStringBuiltInEncodings.UTF16BE.rawValue
            } else if _tagData[pos] == 1 {
                encoding = CFStringBuiltInEncodings.UTF16.rawValue;
                byteOrderMark = true
            }
            let name = String(bytes: frameName, encoding: .utf8)
            if name == "TIT2" || name == "TT2" {
                _title = parseContent(framesize: UInt32(framesize), pos: UInt32(pos) + 1, encoding: encoding, byteOrderMark: byteOrderMark)
                id3_log("ID3 title parsed: \(_title)")
            } else if name == "TPE1" || name == "TP1" {
                _performer = parseContent(framesize: UInt32(framesize), pos: UInt32(pos) + 1, encoding: encoding, byteOrderMark: byteOrderMark)
                id3_log("ID3 performer parsed:\(_performer)")
            } else if name == "APIC" {
                var dataPos = pos + 1
                var imageType: [UInt8] = []
                for i in dataPos..<(dataPos + 65) {
                    if _tagData[i] != 0 {
                        imageType.append(_tagData[i])
                    } else { break }
                }
                dataPos += imageType.count + 1
                let type = String(bytes: imageType, encoding: .utf8)
                let jpeg = type == "image/jpeg"
                let png = type == "image/png"
                if  jpeg || png {
//                  Skip the image description
                    var startPos = dataPos
                    let totalCount = _tagData.count - 2
                    while dataPos < totalCount {
                        let first = _tagData[dataPos]
                        let second = _tagData[dataPos + 1]
                        if jpeg {
                            if first == 0xFF, second == 0xD8 {
                                startPos = dataPos
                                break
                            }
                        } else if png, dataPos + 3 < _tagData.count - 1{
                            let thrid = _tagData[dataPos + 2]
                            let forth = _tagData[dataPos + 3]
                            if first == 0x89, second == 0x50, thrid == 0x4E, forth == 0x47 {
                                startPos = dataPos
                                break
                            }
                        }
                        dataPos += 1
                    }
                    id3_log("Image type \(type), parsing, dataPos:\(dataPos)")
                    if _majorVersion == 3 {
                        framesize = Int((i << 24) + (ii << 16) + (iii << 8) + iv)
                        id3_log("framesize change due to _majorVersion 3 :\(framesize))")
                    }
                    let coverArtSize = framesize - (startPos - pos)
                    id3_log("image size:\(coverArtSize)")
                    let start = _tagData.startIndex.advanced(by: startPos)
                    let end = start.advanced(by: coverArtSize)
                    let d = _tagData.subdata(in: Range(uncheckedBounds: (start, end)))
                    _coverArt = d
                    #if DEBUG
                        let startI = d.startIndex
                        let endI = d.startIndex.advanced(by: 10)
                        let prefix = d.subdata(in: Range(uncheckedBounds: (startI, endI))).map{$0}
                        id3_log("_coverArt, prefix 10 bit:\(prefix)")
                    #endif
                } else {
                    id3_log("\(type) is an unknown type for image data, skipping")
                }
            } else {
                // Unknown/unhandled frame
                id3_log("Unknown/unhandled frame: \(name), size \(framesize)")
            }
            pos += framesize
        }
        
        // Push out the metadata
        if let d = delegate {
            var metadataMap = [String : Metadata]()
            if !_performer.isEmpty {
                metadataMap[MetaDataKey.artist.rawValue] = Metadata.text(_performer)
            }
            if !_title.isEmpty {
                metadataMap[MetaDataKey.title.rawValue] = Metadata.text(_title)
            }
            if let d = _coverArt {
                metadataMap[MetaDataKey.cover.rawValue] = Metadata.data(d)
            }
            if metadataMap.count > 0 {
                DispatchQueue.main.async { d.id3metaDataAvailable(metaData: metadataMap) }
            }
        }
        DispatchQueue.main.async {
            self._tagData.removeAll()
            self.setState(state: .tagParsed)
            self._parsing = false
        }
    }
}

extension Array {
    subscript(fp_safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

