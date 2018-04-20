// The MIT License (MIT)
//
// Copyright (c) 2015-2018 Alexander Grebenyuk (github.com/kean).

import XCTest
import Foundation

extension XCTestCase {
    func test(_ name: String, _ closure: @escaping () -> Void) {
        closure()
    }

    func expect(_ block: (_ fulfill: @escaping () -> Void) -> Void) {
        let expectation = makeExpectation()
        block({ expectation.fulfill() })
    }

    func makeExpectation() -> XCTestExpectation {
        return self.expectation(description: "GenericExpectation")
    }
    
    func expectNotification(_ name: Notification.Name, object: AnyObject? = nil, handler: XCTNSNotificationExpectation.Handler? = nil) -> XCTestExpectation {
        return self.expectation(forNotification: name, object: object, handler: handler)
    }

    func wait(_ timeout: TimeInterval = 5.0, handler: XCWaitCompletionHandler? = nil) {
        self.waitForExpectations(timeout: timeout, handler: handler)
    }
}


func rnd() -> Int {
    return Int(arc4random())
}

func rnd(_ uniform: Int) -> Int {
    return Int(arc4random_uniform(UInt32(uniform)))
}

extension Array {
    func randomItem() -> Element {
        let index = Int(arc4random_uniform(UInt32(self.count)))
        return self[index]
    }
}
