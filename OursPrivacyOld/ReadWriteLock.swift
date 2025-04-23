//
//  ReadWriteLock.swift
//  OursPrivacy
//
//  Copyright © 2025 Ours Wellness Inc.  All rights reserved.
//
//  Created by Hairuo Sang on 8/9/17.
//  Copyright © 2017 OursPrivacy. All rights reserved.
//
import Foundation

class ReadWriteLock {
    private let concurrentQueue: DispatchQueue

    init(label: String) {
        concurrentQueue = DispatchQueue(label: label, qos: .utility, attributes: .concurrent, autoreleaseFrequency: .workItem)
    }

    func read(closure: () -> Void) {
        concurrentQueue.sync {
            closure()
        }
    }
    func write<T>(closure: () -> T) -> T {
        concurrentQueue.sync(flags: .barrier, execute: {
            closure()
        })
    }
}
