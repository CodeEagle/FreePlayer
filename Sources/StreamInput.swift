//
//  InputStreamProtocol.swift
//  FreePlayer
//
//  Created by Lincoln Law on 2017/2/19.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//

import Foundation

protocol StreamInputDelegate: class {
    func streamIsReadyRead()
    func streamHasBytesAvailable(data: UnsafePointer<UInt8>, numBytes: UInt32)
    func streamEndEncountered()
    func streamErrorOccurred(errorDesc: String)
    func streamMetaDataAvailable( metaData: [String: String])
    func streamMetaDataByteSizeAvailable(sizeInBytes: UInt32)
    func streamHasDataCanPlay() -> Bool
}

protocol StreamInputProtocol {
    weak var delegate: StreamInputDelegate? { get set }
    var position: Position { get }
    var contentType: String { get }
    var contentLength: UInt64 { get }
    var errorDescription: String? { get }
    
    @discardableResult func open(_ position: Position) -> Bool
    @discardableResult func open() -> Bool
    func close()
    func setScheduledInRunLoop(run: Bool)
    func set(url: URL)
}

//public protocol ID3ParserProtocol {
//    func id3metaDataAvailable(metaData: [String : String])
//    func id3tagSizeAvailable(tag size: UInt32)
//}
