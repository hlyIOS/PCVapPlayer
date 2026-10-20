//
//  PCSafeMutableArray.swift
//  PCVapPlayer
//
//  Created by converting from Objective-C
//  Copyright © 2024. All rights reserved.
//

import Foundation

/// 线程安全的可变数组
/// 使用递归锁保证线程安全，允许递归调用
/// 
/// 注意：快速枚举和枚举器不是线程安全的
class PCSafeMutableArray<T>: NSMutableArray {
    private var _arr: NSMutableArray
    private let _lock = NSRecursiveLock()
    
    // MARK: - Initialization
    
    override init() {
        _arr = NSMutableArray()
        super.init()
    }
    
    override init(capacity: Int) {
        _arr = NSMutableArray(capacity: capacity)
        super.init()
    }
    
    convenience init(array: [Any]) {
        self.init()
        _arr = NSMutableArray(array: array)
    }
    
    required init?(coder: NSCoder) {
        _arr = NSMutableArray()
        super.init(coder: coder)
    }
    
    // MARK: - Thread-Safe Operations
    
    private func synchronized<T>(_ block: () -> T) -> T {
        _lock.lock()
        defer { _lock.unlock() }
        return block()
    }
    
    /// 在锁内执行 block，保证整段逻辑的原子性（可重入，与 NSRecursiveLock 配合）
    /// 用于需要多步操作保持一致性的场景，避免与其他线程交错导致越界等问题
    func withLock<T>(_ block: () -> T) -> T {
        synchronized(block)
    }
    
    // MARK: - NSArray Protocol
    
    override var count: Int {
        synchronized { _arr.count }
    }
    
    override func object(at index: Int) -> Any {
        synchronized { _arr.object(at: index) }
    }
    
    override subscript(idx: Int) -> Any {
        get {
            synchronized { _arr[idx] }
        }
        set {
            synchronized { _arr[idx] = newValue }
        }
    }
    
    override func contains(_ anObject: Any) -> Bool {
        synchronized { _arr.contains(anObject) }
    }
    
    override func index(of anObject: Any) -> Int {
        synchronized { _arr.index(of: anObject) }
    }
    
    override var firstObject: Any? {
        synchronized { _arr.firstObject }
    }
    
    override var lastObject: Any? {
        synchronized { _arr.lastObject }
    }
    
    // MARK: - NSMutableArray Protocol
    
    override func add(_ anObject: Any) {
        synchronized { _arr.add(anObject) }
    }
    
    override func insert(_ anObject: Any, at index: Int) {
        synchronized { _arr.insert(anObject, at: index) }
    }
    
    override func removeLastObject() {
        synchronized { _arr.removeLastObject() }
    }
    
    override func removeObject(at index: Int) {
        synchronized { _arr.removeObject(at: index) }
    }
    
    override func replaceObject(at index: Int, with anObject: Any) {
        synchronized { _arr.replaceObject(at: index, with: anObject) }
    }
    
    override func remove(_ anObject: Any) {
        synchronized { _arr.remove(anObject) }
    }
    
    override func removeAllObjects() {
        synchronized { _arr.removeAllObjects() }
    }
    
    override func addObjects(from otherArray: [Any]) {
        synchronized { _arr.addObjects(from: otherArray) }
    }
    
    override func exchangeObject(at idx1: Int, withObjectAt idx2: Int) {
        synchronized { _arr.exchangeObject(at: idx1, withObjectAt: idx2) }
    }
    
    override func removeObjects(in array: [Any]) {
        synchronized { _arr.removeObjects(in: array) }
    }
    
    override func setArray(_ otherArray: [Any]) {
        synchronized { _arr.setArray(otherArray) }
    }
}

