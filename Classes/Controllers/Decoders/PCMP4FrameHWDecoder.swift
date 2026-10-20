//
//  PCMP4FrameHWDecoder.swift
//  PCVapPlayer
//
//  Created by converting from Objective-C
//  Copyright © 2024. All rights reserved.
//

import Foundation
import VideoToolbox
import AVFoundation
import CoreVideo
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#endif

/// MP4 硬件解码错误码
enum PCMP4HWDErrorCode: Int {
    case fileNotExist = 10000              // 文件不存在
    case invalidMP4File = 10001            // 非法的 mp4 文件
    case canNotGetStreamInfo = 10002        // 无法获取视频流信息
    case canNotGetStream = 10003            // 无法获取视频流
    case errorCreateVTBDesc = 10004         // 创建 desc 失败
    case errorCreateVTBSession = 10005      // 创建 session 失败
}

let PCMP4HWDErrorDomain = "PCMP4HWDErrorDomain"

/// MP4 硬件解码器
class PCMP4FrameHWDecoder: PCBaseDecoder {
    /// 用于判断当前是否已在专用解码队列上执行（避免 `decodeQueue.sync` 同队列死锁）
    private static let decodeQueueSpecificKey = DispatchSpecificKey<UInt8>()
    private var buffers: PCSafeMutableArray<Any>?
    private var videoStream: Int = -1
    private var outputWidth: Int = 0
    private var outputHeight: Int = 0
    private var status: OSStatus = noErr
    private var isFinish: Bool = false
    private var mDecodeSession: VTDecompressionSession?
    private var mFormatDescription: CMFormatDescription?
    private var finishFrameIndex: Int = -1
    private var constructErr: Error?
    private var mp4Parser: PCMP4ParserProxy?
    private var invalidRetryCount: Int = 0
    
    private let decodeQueue: DispatchQueue
    private var ppsData: Data?  // Picture Parameter Set
    private var spsData: Data?  // Sequence Parameter Set
    private var vpsData: Data?  // Video Parameter Set
    private var lastDecodeFrame: Int = -1
    private var pendingDecodeFrames: Set<Int> = []  // 正在解码中的帧索引（用于初始化阶段）
    
    /// 重置 lastDecodeFrame，用于 seek 操作
    func resetLastDecodeFrame() {
        lastDecodeFrame = -1
        pendingDecodeFrames.removeAll()
        PCVAPInfo(kPCVAPModuleCommon, "resetLastDecodeFrame: reset to -1 for seek operation")
    }
    
    required init(fileInfo: PCBaseDFileInfo) throws {
        self.decodeQueue = DispatchQueue(label: "com.qgame.vap.decode")
        decodeQueue.setSpecific(key: Self.decodeQueueSpecificKey, value: 1)
        self.buffers = nil
        self.lastDecodeFrame = -1
        
        try super.init(fileInfo: fileInfo)
        
        guard let mp4FileInfo = fileInfo as? PCMP4HWDFileInfo else {
            throw NSError(domain: PCMP4HWDErrorDomain, code: PCMP4HWDErrorCode.invalidMP4File.rawValue, userInfo: [NSLocalizedDescriptionKey: "Invalid MP4 file info"])
        }
        
        self.mp4Parser = mp4FileInfo.mp4Parser
        
        // 初始化解码会话
        let isOpenSuccess = onInputStart()
        if !isOpenSuccess {
            PCVAPEvent(kPCVAPModuleCommon, "onInputStart fail!")
            throw constructErr ?? NSError(domain: PCMP4HWDErrorDomain, code: PCMP4HWDErrorCode.canNotGetStreamInfo.rawValue, userInfo: [NSLocalizedDescriptionKey: "Failed to start input"])
        }
        
        registerNotification()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        onInputEnd()
        if let fileInfoImpl = fileInfo as? PCBaseDFileInfoImpl {
            fileInfoImpl.occupiedCount -= 1
        }
    }
    
    /// 获取错误描述
    static func errorDescription(for errorCode: PCMP4HWDErrorCode) -> String {
        let errorDescs = [
            "文件不存在",
            "非法文件格式",
            "无法获取视频流信息",
            "无法获取视频流",
            "VTB创建desc失败",
            "VTB创建session失败"
        ]
        
        switch errorCode {
        case .fileNotExist:
            return errorDescs[0]
        case .invalidMP4File:
            return errorDescs[1]
        case .canNotGetStreamInfo:
            return errorDescs[2]
        case .canNotGetStream:
            return errorDescs[3]
        case .errorCreateVTBDesc:
            return errorDescs[4]
        case .errorCreateVTBSession:
            return errorDescs[5]
        }
    }
    
    // MARK: - PCBaseDecoder Override
    
    override func decodeFrame(_ frameIndex: Int, buffers: NSMutableArray) throws {
        if frameIndex == currentDecodeFrame {
            PCVAPEvent(kPCVAPModuleCommon, "decodeFrame(\(frameIndex)): already in decode")
            return
        }
        
        PCVAPInfo(kPCVAPModuleCommon, "decodeFrame(\(frameIndex)): called, currentDecodeFrame=\(currentDecodeFrame), lastDecodeFrame=\(lastDecodeFrame)")
        currentDecodeFrame = frameIndex
        // 修复：直接使用传入的 buffers 参数，而不是创建新数组
        // buffers 参数就是 bufferManager.buffers（PCSafeMutableArray），直接使用同一个对象引用
        // 这样帧会被添加到 bufferManager.buffers 中，而不是解码器自己的 buffers
        guard let safeBuffers = buffers as? PCSafeMutableArray<Any> else {
            PCVAPError(kPCVAPModuleCommon, "decodeFrame(\(frameIndex)): buffers is not PCSafeMutableArray, type=\(type(of: buffers))")
            // 如果类型不匹配，创建一个新的数组（这种情况不应该发生）
            let safeArray = PCSafeMutableArray<Any>()
            for i in 0..<buffers.count {
                let obj = buffers.object(at: i)
                safeArray.add(obj)
            }
            self.buffers = safeArray
            return
        }
        self.buffers = safeBuffers
        PCVAPInfo(kPCVAPModuleCommon, "decodeFrame(\(frameIndex)): using bufferManager.buffers directly, current buffer count=\(safeBuffers.count)")
        
            decodeQueue.async { [weak self] in
            guard let self = self else { 
                PCVAPError(kPCVAPModuleCommon, "decodeFrame(\(frameIndex)): self is nil in async block")
                return 
            }
            
            PCVAPInfo(kPCVAPModuleCommon, "decodeFrame(\(frameIndex)): async block started, lastDecodeFrame=\(self.lastDecodeFrame), pendingDecodeFrames=\(self.pendingDecodeFrames)")
            
            // 修复：初始化阶段允许连续解码
            // 问题：lastDecodeFrame 的更新在异步回调中，所以当帧 1 的检查执行时，lastDecodeFrame 可能还是 -1
            // 解决方案：在初始化阶段（lastDecodeFrame == -1），允许从 0 开始连续解码
            // 使用 pendingDecodeFrames 来跟踪正在解码的帧，确保连续性
            if self.lastDecodeFrame == -1 {
                // 初始化阶段：允许从 0 开始，并且允许连续解码
                // 检查是否是连续的帧（0, 1, 2, 3, 4...）
                if frameIndex < 0 {
                    PCVAPError(kPCVAPModuleCommon, "decodeFrame(\(frameIndex)): invalid frame index in init phase")
                    return
                }
                // 检查是否连续：要么是 0，要么是 pendingDecodeFrames 中的最大值 + 1
                let maxPending = self.pendingDecodeFrames.max() ?? -1
                if frameIndex != 0 && frameIndex != maxPending + 1 {
                    PCVAPEvent(kPCVAPModuleCommon, "decodeFrame(\(frameIndex)): skipping in init phase, expected \(maxPending + 1) but got \(frameIndex), pendingDecodeFrames=\(self.pendingDecodeFrames)")
                    return
                }
                // 添加到待解码集合
                self.pendingDecodeFrames.insert(frameIndex)
                PCVAPInfo(kPCVAPModuleCommon, "decodeFrame(\(frameIndex)): added to pendingDecodeFrames, now=\(self.pendingDecodeFrames)")
            } else if frameIndex != self.lastDecodeFrame + 1 {
                // 正常解码阶段：必须是依次增大
                PCVAPEvent(kPCVAPModuleCommon, "decodeFrame(\(frameIndex)): skipping, expected \(self.lastDecodeFrame + 1) but got \(frameIndex)")
                return
            }
            
            PCVAPInfo(kPCVAPModuleCommon, "decodeFrame(\(frameIndex)): calling _decodeFrame")
            self._decodeFrame(frameIndex, drop: false)
        }
    }
    
    override func shouldStopDecode(_ nextFrameIndex: Int) -> Bool {
        return isFinish
    }
    
    override func isFrameIndexBeyondEnd(_ frameIndex: Int) -> Bool {
        if finishFrameIndex > 0 {
            return frameIndex >= finishFrameIndex
        }
        return false
    }
    
    // MARK: - Private Methods
    
    private func registerNotification() {
        // 注册通知（如果需要）
    }
    
    private func hwd_didReceiveEnterBackgroundNotification(_ notification: Notification) {
        // 处理进入后台通知
    }
    
    private func _decodeFrame(_ frameIndex: Int, drop: Bool) {
        PCVAPInfo(kPCVAPModuleCommon, "_decodeFrame(\(frameIndex)): started, isFinish=\(isFinish)")
        
        if isFinish {
            PCVAPEvent(kPCVAPModuleCommon, "_decodeFrame(\(frameIndex)): skipping, isFinish=true")
            return
        }
        
        guard let buffers = buffers else {
            PCVAPError(kPCVAPModuleCommon, "_decodeFrame(\(frameIndex)): buffers is nil")
            return
        }
        
        if spsData == nil || ppsData == nil {
            PCVAPError(kPCVAPModuleCommon, "_decodeFrame(\(frameIndex)): spsData or ppsData is nil, spsData=\(spsData != nil ? "exists" : "nil"), ppsData=\(ppsData != nil ? "exists" : "nil")")
            return
        }
        
        PCVAPInfo(kPCVAPModuleCommon, "_decodeFrame(\(frameIndex)): reading packet data")
        
        // 解码开始时间
        let startDate = Date()
        
        guard let packetData = mp4Parser?.readPacketOfSample(frameIndex), !packetData.isEmpty else {
            PCVAPError(kPCVAPModuleCommon, "_decodeFrame(\(frameIndex)): failed to read packet data or packet is empty")
            finishFrameIndex = frameIndex
            _onInputEnd()
            return
        }
        
        PCVAPInfo(kPCVAPModuleCommon, "_decodeFrame(\(frameIndex)): packet data read, size=\(packetData.count) bytes")
        
        // 获取当前帧pts,pts是在parse mp4 box时得到的
        guard let videoSamples = mp4Parser?.videoSamples,
              frameIndex < videoSamples.count else {
            return
        }
        
        let videoSample = videoSamples[frameIndex]
        let currentPts = videoSample.pts
        
        // 创建 CMBlockBuffer
        var blockBuffer: CMBlockBuffer?
            status = packetData.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return OSStatus(-1) // kCMBlockBufferAllocationFailedErr
            }
            // 注意：这里需要复制数据，因为原始数据可能会被释放
            let dataCopy = UnsafeMutableRawPointer.allocate(byteCount: packetData.count, alignment: 1)
            dataCopy.copyMemory(from: baseAddress, byteCount: packetData.count)
            
            return CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: dataCopy,
                blockLength: packetData.count,
                blockAllocator: kCFAllocatorDefault, // 使用默认分配器以便自动释放
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: packetData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        
        guard status == noErr, let blockBuffer = blockBuffer else {
            return
        }
        
        // 创建 CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        let sampleSizeArray = [packetData.count]
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: mFormatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: sampleSizeArray,
            sampleBufferOut: &sampleBuffer
        )
        
        // CMBlockBuffer 会自动管理内存，不需要手动释放
        
        guard let sampleBuffer = sampleBuffer else {
            return
        }
        
        guard let decodeSession = mDecodeSession else {
            return
        }
        
        // 使用 VTDecompressionSessionDecodeFrame
        var flagOut: VTDecodeInfoFlags = []
        let flags: VTDecodeFrameFlags = []
        
//        PCVAPInfo(kPCVAPModuleCommon, "_decodeFrame(\(frameIndex)): calling VTDecompressionSessionDecodeFrame")
        status = VTDecompressionSessionDecodeFrame(
            decodeSession,
            sampleBuffer: sampleBuffer,
            flags: flags,
            infoFlagsOut: &flagOut
        ) { [weak self] status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration in
            guard let self = self else { 
//                PCVAPError(kPCVAPModuleCommon, "VTDecompressionSessionDecodeFrame callback: self is nil for frame \(frameIndex)")
                return 
            }
            
//            PCVAPInfo(kPCVAPModuleCommon, "VTDecompressionSessionDecodeFrame callback: frame=\(frameIndex), status=\(status), hasPixelBuffer=\(imageBuffer != nil)")
            self.handleDecodePixelBuffer(
                pixelBuffer: imageBuffer,
                sampleBuffer: sampleBuffer,
                frameIndex: frameIndex,
                currentPts: currentPts,
                startDate: startDate,
                status: status,
                needDrop: drop
            )
        }
        
        if status != noErr {
            PCVAPError(kPCVAPModuleCommon, "_decodeFrame(\(frameIndex)): VTDecompressionSessionDecodeFrame returned error status=\(status)")
        } else {
            PCVAPInfo(kPCVAPModuleCommon, "_decodeFrame(\(frameIndex)): VTDecompressionSessionDecodeFrame called successfully")
        }
        
        if status == kVTInvalidSessionErr {
            // 防止陷入死循环
            if invalidRetryCount >= 3 {
                return
            }
            
            resetDecoder()
            // 从最近I帧一直解码到当前帧，中间帧丢弃
            findKeyFrameAndDecodeToCurrent(frameIndex)
        } else {
            invalidRetryCount = 0
        }
    }
    
    private func handleDecodePixelBuffer(
        pixelBuffer: CVPixelBuffer?,
        sampleBuffer: CMSampleBuffer,
        frameIndex: Int,
        currentPts: UInt64,
        startDate: Date,
        status: OSStatus,
        needDrop: Bool
    ) {
        lastDecodeFrame = frameIndex
        // 从待解码集合中移除（初始化阶段使用）
        pendingDecodeFrames.remove(frameIndex)
        
        // 释放 sampleBuffer
        // CMSampleBuffer 会自动管理内存
        
        if status == kVTInvalidSessionErr {
            PCVAPError(kPCVAPModuleCommon, "decompress fail! frame:\(frameIndex) kVTInvalidSessionErr error:\(status)")
        } else if status == kVTVideoDecoderBadDataErr {
            PCVAPError(kPCVAPModuleCommon, "decompress fail! frame:\(frameIndex) kVTVideoDecoderBadDataErr error:\(status)")
        } else if status != noErr {
            PCVAPError(kPCVAPModuleCommon, "decompress fail! frame:\(frameIndex) error:\(status)")
        }
        
        if needDrop {
            return
        }
        
        guard let pixelBuffer = pixelBuffer else {
            return
        }
        
        let newFrame = PCMP4AnimatedImageFrame()
        // imagebuffer会在frame回收时释放（Swift 中自动管理）
        newFrame.pixelBuffer = pixelBuffer
        newFrame.frameIndex = frameIndex // dts顺序
        let decodeTime = Date().timeIntervalSince(startDate) * 1000
        newFrame.decodeTime = decodeTime
        newFrame.defaultFps = mp4Parser?.fps ?? 0
        newFrame.pts = currentPts
        
        // 插入到缓冲区（整段在锁内执行，避免 count 与 object(at:) 之间被其他线程修改导致越界）
        if let buffers = buffers {
            buffers.withLock {
                PCVAPInfo(kPCVAPModuleCommon, "handleDecodePixelBuffer(\(frameIndex)): adding frame to buffers, current buffer count=\(buffers.count)")
                buffers.add(newFrame)
                let count = buffers.count
                let array = (0..<count).compactMap { buffers.object(at: $0) as? PCMP4AnimatedImageFrame }
                let sortedArray = array.sorted { $0.pts < $1.pts }
                buffers.removeAllObjects()
                for frame in sortedArray {
                    buffers.add(frame)
                }
                PCVAPInfo(kPCVAPModuleCommon, "handleDecodePixelBuffer(\(frameIndex)): frame added and sorted, new buffer count=\(buffers.count)")
            }
        } else {
            PCVAPError(kPCVAPModuleCommon, "handleDecodePixelBuffer(\(frameIndex)): buffers is nil, cannot add frame")
        }
    }
    
    // MARK: - Initialization Methods
    
    private func onInputStart() -> Bool {
        let fileMgr = FileManager.default
        guard fileMgr.fileExists(atPath: fileInfo.filePath) else {
            constructErr = NSError(domain: PCMP4HWDErrorDomain, code: PCMP4HWDErrorCode.fileNotExist.rawValue, userInfo: errorUserInfo())
            return false
        }
        
        isFinish = false
        vpsData = nil
        spsData = nil
        ppsData = nil
        outputWidth = mp4Parser?.picWidth ?? 0
        outputHeight = mp4Parser?.picHeight ?? 0
        
        return initPPSnSPS()
    }
    
    private func initPPSnSPS() -> Bool {
        PCVAPInfo(kPCVAPModuleCommon, "initPPSnSPS")
        
        if spsData != nil && ppsData != nil {
            PCVAPError(kPCVAPModuleCommon, "sps&pps is already has value.")
            return true
        }
        
        guard let mp4Parser = mp4Parser else {
            PCVAPError(kPCVAPModuleCommon, "initPPSnSPS failed: mp4Parser is nil")
            return false
        }
        
        spsData = mp4Parser.spsData
        ppsData = mp4Parser.ppsData
        vpsData = mp4Parser.vpsData
        
        PCVAPInfo(kPCVAPModuleCommon, "initPPSnSPS: videoCodecID=\(mp4Parser.videoCodecID), spsData=\(spsData != nil ? "exists(\(spsData!.count) bytes)" : "nil"), ppsData=\(ppsData != nil ? "exists(\(ppsData!.count) bytes)" : "nil")")
        
        // 创建 CMFormatDescription
        guard let spsData = spsData, let ppsData = ppsData,
              mp4Parser.videoCodecID != .unknown else {
            PCVAPError(kPCVAPModuleCommon, "initPPSnSPS failed: spsData=\(spsData != nil ? "exists" : "nil"), ppsData=\(ppsData != nil ? "exists" : "nil"), videoCodecID=\(mp4Parser.videoCodecID)")
            return false
        }
        
        if mp4Parser.videoCodecID == .h264 {
            // 修复：withUnsafeBytes闭包内的指针只在闭包内有效
            // 解决方案：将数据复制到固定内存位置，确保指针在整个函数执行期间有效
            let spsBytes = [UInt8](spsData)
            let ppsBytes = [UInt8](ppsData)
            
            // 使用withUnsafeBufferPointer获取指针，数组在函数执行期间不会被释放
            var resultStatus: OSStatus = noErr
            var resultFormatDescription: CMFormatDescription?
            
            spsBytes.withUnsafeBufferPointer { spsBuffer in
                ppsBytes.withUnsafeBufferPointer { ppsBuffer in
                    guard let spsPointer = spsBuffer.baseAddress, let ppsPointer = ppsBuffer.baseAddress else {
                        resultStatus = OSStatus(-1)
                        return
                    }
                    
                    let parameterSetPointers = [spsPointer, ppsPointer]
                    let parameterSetSizes = [spsBytes.count, ppsBytes.count]
                    
                    resultStatus = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: parameterSetPointers,
                        parameterSetSizes: parameterSetSizes,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &resultFormatDescription
                    )
                }
            }
            
            status = resultStatus
            mFormatDescription = resultFormatDescription
            
            if status != noErr {
                PCVAPEvent(kPCVAPModuleCommon, "CMVideoFormatDescription. Creation: failed. status=\(status), spsSize=\(spsBytes.count), ppsSize=\(ppsBytes.count)")
                PCVAPError(kPCVAPModuleCommon, "CMVideoFormatDescription creation failed with status: \(status)")
                constructErr = NSError(domain: PCMP4HWDErrorDomain, code: PCMP4HWDErrorCode.errorCreateVTBDesc.rawValue, userInfo: errorUserInfo())
                return false
            }
            
            PCVAPEvent(kPCVAPModuleCommon, "CMVideoFormatDescription. Creation: successfully.")
        } else if mp4Parser.videoCodecID == .h265 {
            guard VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) else {
                PCVAPEvent(kPCVAPModuleCommon, "H.265 decoding is un-supported because of the hardware")
                return false
            }
            
            guard let vpsData = vpsData else {
                PCVAPError(kPCVAPModuleCommon, "initPPSnSPS failed: vpsData is nil for H.265")
                return false
            }
            
            // 修复：withUnsafeBytes闭包内的指针只在闭包内有效
            // 解决方案：将数据复制到固定内存位置，确保指针在整个函数执行期间有效
            let vpsBytes = [UInt8](vpsData)
            let spsBytes = [UInt8](spsData)
            let ppsBytes = [UInt8](ppsData)
            
            var resultStatus: OSStatus = noErr
            var resultFormatDescription: CMFormatDescription?
            
            vpsBytes.withUnsafeBufferPointer { vpsBuffer in
                spsBytes.withUnsafeBufferPointer { spsBuffer in
                    ppsBytes.withUnsafeBufferPointer { ppsBuffer in
                        guard let vpsPointer = vpsBuffer.baseAddress,
                              let spsPointer = spsBuffer.baseAddress,
                              let ppsPointer = ppsBuffer.baseAddress else {
                            resultStatus = OSStatus(-1)
                            return
                        }
                        
                        let parameterSetPointers = [vpsPointer, spsPointer, ppsPointer]
                        let parameterSetSizes = [vpsBytes.count, spsBytes.count, ppsBytes.count]
                        
                        resultStatus = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 3,
                            parameterSetPointers: parameterSetPointers,
                            parameterSetSizes: parameterSetSizes,
                            nalUnitHeaderLength: 4,
                            extensions: nil,
                            formatDescriptionOut: &resultFormatDescription
                        )
                    }
                }
            }
            
            status = resultStatus
            mFormatDescription = resultFormatDescription
            
            if status != noErr {
                PCVAPEvent(kPCVAPModuleCommon, "CMVideoFormatDescription. Creation: failed. status=\(status), vpsSize=\(vpsBytes.count), spsSize=\(spsBytes.count), ppsSize=\(ppsBytes.count)")
                PCVAPError(kPCVAPModuleCommon, "CMVideoFormatDescription creation failed with status: \(status)")
                constructErr = NSError(domain: PCMP4HWDErrorDomain, code: PCMP4HWDErrorCode.errorCreateVTBDesc.rawValue, userInfo: errorUserInfo())
                return false
            }
            
            PCVAPEvent(kPCVAPModuleCommon, "CMVideoFormatDescription. Creation: successfully.")
        }
        
        // 创建 VTDecompressionSession
        return createDecompressionSession()
    }
    
    private func createDecompressionSession() -> Bool {
        guard let formatDescription = mFormatDescription else {
            return false
        }
        
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        
        let pixelBufferAttributes = attrs as CFDictionary
        
        status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: pixelBufferAttributes,
            outputCallback: nil,
            decompressionSessionOut: &mDecodeSession
        )
        
        if status != noErr {
            constructErr = NSError(domain: PCMP4HWDErrorDomain, code: PCMP4HWDErrorCode.errorCreateVTBSession.rawValue, userInfo: errorUserInfo())
            return false
        }
        
        return true
    }
    
    private func resetDecoder() {
        // 删除旧的 session
        if let decodeSession = mDecodeSession {
            VTDecompressionSessionWaitForAsynchronousFrames(decodeSession)
            VTDecompressionSessionInvalidate(decodeSession)
            mDecodeSession = nil
        }
        
        // 重新创建
        _ = createDecompressionSession()
    }
    
    /// 必须在 `decodeQueue` 上调用：从关键帧顺序解码到目标帧（中间帧可丢弃）
    private func decodeFromKeyFrameToCurrent(keyframeIndex: Int, frameIndex: Int) {
        var currentIndex = keyframeIndex
        while currentIndex < frameIndex {
            _decodeFrame(currentIndex, drop: true)
            currentIndex += 1
        }
        _decodeFrame(frameIndex, drop: false)
    }
    
    /// Seek 到指定帧：从最近的关键帧解码到目标帧
    /// - Parameter frameIndex: 目标帧索引
    func findKeyFrameAndDecodeToCurrent(_ frameIndex: Int) {
        NotificationCenter.default.post(name: kPCVAPDecoderSeekStart, object: self)
        
        PCVAPInfo(kPCVAPModuleCommon, "findKeyFrameAndDecodeToCurrent: seeking to frame \(frameIndex)")
        
        guard let keyframeIndexes = mp4Parser?.videoSyncSampleIndexes else {
            PCVAPError(kPCVAPModuleCommon, "findKeyFrameAndDecodeToCurrent: no keyframe indexes found")
            NotificationCenter.default.post(name: kPCVAPDecoderSeekFinish, object: self)
            return
        }
        
        var index = keyframeIndexes.first ?? 0
        for number in keyframeIndexes {
            if number < frameIndex {
                index = number
                continue
            } else {
                break
            }
        }
        
        PCVAPInfo(kPCVAPModuleCommon, "findKeyFrameAndDecodeToCurrent: found keyframe at \(index), decoding to frame \(frameIndex)")
        
        // 在 decodeQueue 上执行 seek 解码。若调用方已在 decodeQueue（如 kVTInvalidSessionErr 恢复路径），
        // 禁止再 sync 同一条串行队列，否则会死锁（见 stack: _dispatch_sync_f_slow）。
        if DispatchQueue.getSpecific(key: Self.decodeQueueSpecificKey) != nil {
            decodeFromKeyFrameToCurrent(keyframeIndex: index, frameIndex: frameIndex)
        } else {
            decodeQueue.sync { [self] in
                decodeFromKeyFrameToCurrent(keyframeIndex: index, frameIndex: frameIndex)
            }
        }
        
        var targetFrameDecoded = false
        
        // 等待目标帧解码完成（最多等待 2 秒）
        // 注意：这是一个简化的实现，实际应该通过回调来通知
        // 我们通过检查 lastDecodeFrame 来判断是否完成
        let timeout: TimeInterval = 2.0
        let startTime = Date()
        while !targetFrameDecoded && Date().timeIntervalSince(startTime) < timeout {
            if lastDecodeFrame >= frameIndex {
                targetFrameDecoded = true
                PCVAPInfo(kPCVAPModuleCommon, "findKeyFrameAndDecodeToCurrent: target frame \(frameIndex) decoded, lastDecodeFrame=\(lastDecodeFrame)")
                break
            }
            Thread.sleep(forTimeInterval: 0.01) // 等待 10ms
        }
        
        if !targetFrameDecoded {
            PCVAPError(kPCVAPModuleCommon, "findKeyFrameAndDecodeToCurrent: timeout waiting for frame \(frameIndex) to decode, lastDecodeFrame=\(lastDecodeFrame)")
        }
        
        PCVAPInfo(kPCVAPModuleCommon, "findKeyFrameAndDecodeToCurrent: seek completed, lastDecodeFrame=\(lastDecodeFrame)")
        
        NotificationCenter.default.post(name: kPCVAPDecoderSeekFinish, object: self)
    }
    
    private func _onInputEnd() {
        if isFinish {
            return
        }
        
        isFinish = true
        
        if let decodeSession = mDecodeSession {
            VTDecompressionSessionWaitForAsynchronousFrames(decodeSession)
            VTDecompressionSessionInvalidate(decodeSession)
            mDecodeSession = nil
        }
        
        if spsData != nil || ppsData != nil || vpsData != nil {
            spsData = nil
            ppsData = nil
            vpsData = nil
        }
        
        // CMFormatDescription 会自动管理内存
        mFormatDescription = nil
    }
    
    private func onInputEnd() {
        // 为确保任务停止，必须同步执行
        if Thread.isMainThread {
            decodeQueue.sync { [weak self] in
                self?._onInputEnd()
            }
        } else {
            decodeQueue.async { [weak self] in
                self?._onInputEnd()
            }
        }
    }
    
    private func errorUserInfo() -> [String: Any] {
        return ["location": fileInfo.filePath ?? ""]
    }
}

// MARK: - UIDevice Extension

#if canImport(UIKit)
extension UIDevice {
    var hwd_isSimulator: Bool {
        struct Static {
            static var isSimulator: Bool = false
            static var onceToken: Int = 0
        }
        
        if Static.onceToken == 0 {
            let model = machineName
            Static.isSimulator = (model == "x86_64" || model == "i386")
            Static.onceToken = 1
        }
        return Static.isSimulator
    }
    
    private var machineName: String {
        struct Static {
            static var name: String = ""
            static var onceToken: Int = 0
        }
        
        if Static.onceToken == 0 {
            var size = 0
            sysctlbyname("hw.machine", nil, &size, nil, 0)
            var machineName = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.machine", &machineName, &size, nil, 0)
            Static.name = String(cString: machineName)
            Static.onceToken = 1
        }
        return Static.name
    }
}
#endif
