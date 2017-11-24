//
//  ID3Parser.swift
//  FreePlayer
//
//  Created by Lincoln Law on 2017/3/5.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//
import Foundation

protocol ID3ParserDelegate: class {
    func id3metaDataAvailable(metaData: [MetaDataKey : Metadata])
    func id3tagSizeAvailable(tag size: UInt32)
    func id3tagParsingDone()
}

final class ID3Parser {

    weak var delegate: ID3ParserDelegate?
    private lazy var _state: State = .initial
    private lazy var _tagData: Data = Data()
    private lazy var _bytesReceived = UInt32()
    private lazy var _majorVersion = UInt8()
    private lazy var _hasFooter = false
    private lazy var _usesUnsynchronisation = false
    private lazy var _usesExtendedHeader = false
    private lazy var _title = ""
    private lazy var _album = ""
    private lazy var _performer = ""
    private lazy var _coverArt: Data? = nil
    private lazy var _lastData: Data? = nil
    private lazy var _lock: OSSpinLock = OS_SPINLOCK_INIT
    private lazy var _parsing = false
    private lazy var _syncQueue = DispatchQueue(label: "id3.sync")
//    private lazy var _queue = RunloopQueue(named: "StreamProvider.id3.parser")
    private var _hasV1Tag = false { didSet { totalTagSize() } }
    private var _tagSize = UInt32() { didSet { totalTagSize() } }
    private lazy var _v1TagDeal = false
    private lazy var _v2TagDeal = false
    enum State {
        case initial
        case parseFrames
        case tagParsed
        case notID3V2
    }

    private struct ID3V1Length {
        static var header: Int { return 3 }
        static var title: Int { return 30 }
        static var artist: Int { return 30 }
        static var album: Int { return 30 }
        static var year: Int { return 4 }
        static var comment: Int { return 30 }
        static var genre: Int { return 4 }
    }

    deinit { id3_log("ID3Parser deinit") }
    
    init() {}
}

extension ID3Parser {
    func setState(state: State) {
        _state = state
        if state == .tagParsed {
            delegate?.id3tagParsingDone()
        }
    }

    func parseContent(framesize: UInt32, pos: UInt32, encoding: CFStringEncoding, byteOrderMark: Bool) -> String {
        func un(raw: UnsafeMutablePointer<UInt8>) -> UnsafeMutablePointer<UInt8> { return raw }
        let pointer = _tagData.withUnsafeMutableBytes({ (item: UnsafeMutablePointer<UInt8>) in
            item
        }).advanced(by: Int(pos))
        guard framesize > 1 else { return "" }
        let size = framesize - 1
        return CFStringCreateWithBytes(kCFAllocatorDefault, pointer, Int(size), encoding, byteOrderMark) as String
    }
}

extension ID3Parser {

    func reset() {
        _state = .initial
        _bytesReceived = 0
        _majorVersion = 0
        _v1TagDeal = false
        _v2TagDeal = false
        _tagSize = 0
        _hasFooter = false
        _usesUnsynchronisation = false
        _usesExtendedHeader = false
        _tagData.removeAll()
    }

    func wantData() -> Bool {
        let done = [State.tagParsed].contains(_state)
        return done == false
    }

    func totalTagSize() {
        guard _v1TagDeal, _v2TagDeal else { return }
        var final = _tagSize
        if _hasV1Tag { final += 128 }
        delegate?.id3tagSizeAvailable(tag: final)
    }

    func detechV1(with url: URL?, total: UInt) {
        DispatchQueue.global(qos: .utility).async {
            guard let u = url else {
                self._v1TagDeal = true
                self._hasV1Tag = false
                return
            }
            let scheme = u.scheme?.lowercased()
            let isLocal = scheme == "file"
            let isRemote = isLocal == false
            if isRemote {
                if total < 128 {
                    self._v1TagDeal = true
                    self._hasV1Tag = false
                    return
                }
                var request = URLRequest(url: u)
                request.setValue("bytes=-128", forHTTPHeaderField: "Range")
                NowPlayingInfo.shared.session.dataTask(with: request) { [weak self] data, _, _ in
                    if let d = data, d.count == 4 {
                        let range = Range(uncheckedBounds: (d.startIndex, d.startIndex.advanced(by: 3)))
                        let sub = d.subdata(in: range)
                        let tag = String(data: sub, encoding: .ascii)
                        if tag == "TAG" {
                            DispatchQueue.main.async {
                                self?._v1TagDeal = true
                                self?._hasV1Tag = true
                            }
                            return
                        }
                    }
                    DispatchQueue.main.async {
                        self?._v1TagDeal = true
                        self?._hasV1Tag = false
                    }
                }.resume()
            } else if isLocal {
                let raw = u.absoluteString.replacingOccurrences(of: "file://", with: "")
                var buff = stat()
                if stat(raw.withCString({ $0 }), &buff) != 0 {
                    DispatchQueue.main.async {
                        self._v1TagDeal = true
                        self._hasV1Tag = false
                    }
                    return
                }
                let size = buff.st_size
                if let file = fopen(raw.withCString({ $0 }), "r".withCString({ $0 })) {
                    defer { fclose(file) }
                    fseek(file, -128, SEEK_END)
                    let length = 3
                    var bytes: [UInt8] = Array(repeating: 0, count: length)
                    fread(&bytes, 1, length, file)
                    if String(bytes: bytes, encoding: .utf8) == "TAG" {
                        DispatchQueue.main.async {
                            self._v1TagDeal = true
                            self._hasV1Tag = true
                        }
                        return
                    }
                }
                DispatchQueue.main.async {
                    self._v1TagDeal = true
                    self._hasV1Tag = false
                }
            }
        }
    }

    func feedData(data: UnsafeMutablePointer<UInt8>, numBytes: UInt32) {
        _syncQueue.sync {
            if self.wantData() == false { return }
            if self._state == .tagParsed { return }
            if self._parsing { return }
            self._bytesReceived += numBytes
            let bytesSize = Int(numBytes)
            let raw = malloc(bytesSize)!.assumingMemoryBound(to: UInt8.self)
            defer { free(raw) }
            memcpy(raw, data, bytesSize)
            let dat = Data(bytes: raw, count: bytesSize)
            self._lastData = dat
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
                if len < 128, let d = self._lastData {
                    id3_log("append last data")
                    realData = d + dat
                    len = realData.count
                }
                if len < 128 {
                    id3_log("try parser id3v1 but len:\(len) to short")
                    return
                }
                let start = len - 128
                let v1 = realData[start ..< len]
                let tag = v1.map({ $0 })[0 ..< 3]
                let raw = String(bytes: tag, encoding: .ascii)
                if raw == "TAG" {
                    self.dealV1(with: v1.map({ $0 }))
                }
            }
            if canParseFrames, self._parsing == false {
                 self.parseFrames()
            }
        }
    }

    private func dealV1(with data: [UInt8]) {
        id3_log("tag size: \(_tagSize)")
        if StreamConfiguration.shared.autoFillID3InfoToNowPlayingCenter == false { return }

        let total = [ID3V1Length.header, ID3V1Length.title, ID3V1Length.artist, ID3V1Length.album, ID3V1Length.year, ID3V1Length.comment]
        var offset = 0
        var end = 0
        for (i, len) in total.enumerated() {
            if i == 0 {
                offset += len
                continue
            }
            end = len + offset
            let t = offset ..< end
            let range = data[t].flatMap({ $0 })
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
            var metadataMap = [MetaDataKey: Metadata]()
            if _performer.isEmpty == false {
                metadataMap[.artist] = .text(_performer)
            }
            if _title.isEmpty == false {
                metadataMap[.title] = .text(_title)
            }
            if metadataMap.count > 0 {
                DispatchQueue.main.async { d.id3metaDataAvailable(metaData: metadataMap) }
            }
        }
    }

    private func initial() -> Bool {
        // Do we have enough bytes to determine if this is an ID3 tag or not?
        /*
         char Header[3]; /* 必须为"ID3"否则认为标签不存在 */
         char Ver; /* 版本号;ID3V2.3就记录03,ID3V2.4就记录04 */
         char Revision; /* 副版本号;此版本记录为00 */
         char Flag; /* 存放标志的字节，这个版本只定义了三位，稍后详细解说 */
         char Size[4]; /* 标签大小，包括标签帧和标签头。（不包括扩展标签头的10个字节） */
         */
        if _bytesReceived <= 9 { return false }
        let sub = _tagData[0 ... 2]
        let content = String(bytes: sub, encoding: .ascii)
        if content != "ID3" {
            id3_log("Not an ID3v2 tag, bailing out")
            setState(state: .notID3V2)
            _v2TagDeal = true
            return false
        }
        _majorVersion = _tagData[3]
        // Currently support only id3v2.2 and 2.3
        if _majorVersion != 2 && _majorVersion != 3 && _majorVersion != 4 {
            id3_log("ID3v2.\(_majorVersion) not supported by the parser")
            _v2TagDeal = true
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
        var tagsize = six | seven | eight | nine

        if tagsize > 0 {
            if _hasFooter { tagsize += 10 }
            tagsize += 10
            _v2TagDeal = true
            _tagSize = tagsize
            id3_log("tag size: \(_tagSize)")
            if StreamConfiguration.shared.autoFillID3InfoToNowPlayingCenter == false {
                setState(state: .tagParsed)
                return false
            } else {
                setState(state: .parseFrames)
                return true
            }
        }
        _v2TagDeal = true
        setState(state: .notID3V2)
        return false
    }

    private func parseFrames() {
        // Do we have enough data to parse the frames?
        if _tagData.count < Int(_tagSize) {
            id3_log("Not enough data received for parsing, have \(_tagData.count) bytes, need \(_tagSize) bytes")
            DispatchQueue.main.async { self._parsing = false }
            return
        }
        _parsing = true
        var pos = 10
        // Do we have an extended header? If we do, skip it
        if _usesExtendedHeader {
            let i = UInt32(_tagData[pos])
            let ii = UInt32(_tagData[pos + 1])
            let iii = UInt32(_tagData[pos + 2])
            let iv = UInt32(_tagData[pos + 3])
            //            let extendedHeaderSize = Int((i << 21) | (ii << 14) | (iii << 7) | iv)
            let array = [i, ii, iii, iv]
            let extendedHeaderSize = array.toInt(offsetSize: 7)

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
        parsing(from: pos)
        doneParsing()
    }

    private func parsing(from position: Int) {
        var pos = position
        let total = Int(_tagSize)
        while pos < total {
            var frameName: [UInt8] = Array(repeatElement(0, count: 4))
            frameName[0] = _tagData[pos]
            frameName[1] = _tagData[pos + 1]
            frameName[2] = _tagData[pos + 2]

            if _majorVersion >= 3 { frameName[3] = _tagData[pos + 3] }
            else { frameName[3] = 0 }

            var framesize = 0
            var i: UInt32
            var ii: UInt32
            var iii: UInt32
            var iv: UInt32
            if _majorVersion >= 3 {
                pos += 4
                i = UInt32(_tagData[pos])
                ii = UInt32(_tagData[pos + 1])
                iii = UInt32(_tagData[pos + 2])
                iv = UInt32(_tagData[pos + 3])
                //                let a = (i << 21)
                //                let b = (ii << 14)
                //                let c = (iii << 7)
                let array = [i, ii, iii, iv]
                framesize = array.toInt(offsetSize: 7)
                //                framesize = Int( a + b + c + iv)
            } else {
                i = UInt32(_tagData[pos])
                ii = UInt32(_tagData[pos + 1])
                iii = UInt32(_tagData[pos + 2])
                iv = 0
                let array = [i, ii, iii, iv]
                framesize = array.toInt(offsetSize: 8)
                //                framesize = Int((i << 16) + (ii << 8) + iii)
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
                encoding = CFStringBuiltInEncodings.UTF16.rawValue
                byteOrderMark = true
            }
            let name = String(bytes: frameName, encoding: .utf8) ?? ""
            if name == "TIT2" || name == "TT2" {
                _title = parseContent(framesize: UInt32(framesize), pos: UInt32(pos) + 1, encoding: encoding, byteOrderMark: byteOrderMark)
                id3_log("ID3 title parsed: \(_title)")
            } else if name == "TALB" {
                _album = parseContent(framesize: UInt32(framesize), pos: UInt32(pos) + 1, encoding: encoding, byteOrderMark: byteOrderMark)
                id3_log("ID3 album parsed: \(_album)")
            } else if name == "TPE1" || name == "TP1" {
                _performer = parseContent(framesize: UInt32(framesize), pos: UInt32(pos) + 1, encoding: encoding, byteOrderMark: byteOrderMark)
                id3_log("ID3 performer parsed:\(_performer)")
            } else if name == "APIC" {
                var dataPos = pos + 1
                var imageType: [UInt8] = []
                for i in dataPos ..< (dataPos + 65) {
                    if _tagData[i] != 0 {
                        imageType.append(_tagData[i])
                    } else { break }
                }
                dataPos += imageType.count + 1
                let type = String(bytes: imageType, encoding: .utf8) ?? ""
                let jpeg = type == "image/jpeg" || type == "image/jpg"
                let png = type == "image/png"
                if jpeg || png {
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
                        } else if png, dataPos + 3 < _tagData.count - 1 {
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
                        //                        let a = (i << 24)
                        //                        let b = (ii << 16)
                        //                        let c = (iii << 8)
                        //                        framesize = Int( a + b + c + iv)
                        let array = [i, ii, iii, iv]
                        framesize = array.toInt(offsetSize: 8)
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
                        let prefix = d.subdata(in: Range(uncheckedBounds: (startI, endI))).map { $0 }
                        id3_log("_coverArt, prefix 10 bit:\(prefix)")
                    #endif
                } else {
                    id3_log("->|\(type)|<- is an unknown type for image data, skipping")
                }
            } else {
                // Unknown/unhandled frame
                id3_log("Unknown/unhandled frame: \(name), size \(framesize)")
            }
            pos += framesize
        }
    }

    private func doneParsing() {
        // Push out the metadata
        if let d = delegate {
            var metadataMap = [MetaDataKey: Metadata]()
            if _performer.isEmpty == false {
                metadataMap[MetaDataKey.artist] = Metadata.text(_performer)
            }
            if _album.isEmpty == false {
                metadataMap[MetaDataKey.album] = Metadata.text(_album)
            }
            if _title.isEmpty == false {
                metadataMap[MetaDataKey.title] = Metadata.text(_title)
            }
            if let d = _coverArt {
                metadataMap[MetaDataKey.cover] = Metadata.data(d)
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


extension Array where Element == UInt32 {
    func toInt(offsetSize: Int) -> Int {
        let total = count
        var totalSize = 0
        for i in 0 ..< total {
            totalSize += Int(UInt32(self[i]) << (offsetSize * ((total - 1) - i)))
        }
        return totalSize
    }
}
