//
//  FreePlayerTests.swift
//  FreePlayerTests
//
//  Created by Lincoln Law on 2017/2/19.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//

import XCTest
@testable import FreePlayer

class FreePlayerTests: XCTestCase {
    
    fileprivate var data: AudioStream?
    
    override func setUp() {
        super.setUp()
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }
    
    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        super.tearDown()
    }
    
    func testHttpStream() {
        let hs = HttpStream()
        hs.createReadStream(from: URL(string: "http://mp3-cdn.luoo.net/low/luoo/radio896/02.mp3"))
    }
    
    func testPerformanceExample() {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }
    
    func asyncTest(timeout: TimeInterval = 30, block: (XCTestExpectation) -> ()) {
        let expectation: XCTestExpectation = self.expectation(description: "❌:Timeout")
        block(expectation)
        self.waitForExpectations(timeout: timeout) { (error) in
            if error != nil {
                XCTFail("time out: \(error)")
            } else {
                XCTAssert(true, "success")
            }
        }
    }
    
}

extension FreePlayerTests {
    
    func testOutPut() {
        let path = Bundle(for: FreePlayerTests.self).bundlePath.replacingOccurrences(of: "FreePlayerTests.xctest", with: "out.txt")
        let output = StreamOutputManager(fileURL: URL(fileURLWithPath: path))
        guard let data = "hello world😄".data(using: .utf8) else { return }
        data.withUnsafeBytes { (d: UnsafePointer<UInt8>) -> Void in
            output.write(data: d, length: data.count)
        }
        guard let data2 = "hello world😄2222".data(using: .utf8) else { return }
        data2.withUnsafeBytes { (d: UnsafePointer<UInt8>) -> Void in
            output.write(data: d, length: data2.count)
        }
    }
    
    func testConfiguration() {
//        _ = StreamConfiguration.shared
//        let queue = AudioQueue()
//        queue.start()
//        queue.stop()
        asyncTest { (e) in
            data = AudioStream()
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: { 
                e.fulfill()
            })
        }
        
        
    }
}
