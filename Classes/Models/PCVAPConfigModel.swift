//
//  PCVAPConfigModel.swift
//  PCVapPlayer
//
//  Created by converting from Objective-C
//  Copyright © 2024. All rights reserved.
//

import Foundation
import UIKit
import Metal

// MARK: - Enums

/// VAP 方向
public enum VAPOrientation: Int {
    case none = 0          // 兼容
    case portrait = 1      // 竖屏
    case landscape = 2     // 横屏
}

// MARK: - Type Aliases

public typealias AttachmentSourceType = String      // 资源类型
public typealias AttachmentSourceLoadType = String  // 资源加载类型
public typealias AttachmentSourceStyle = String     // 字体
public typealias AttachmentFitType = String         // 资源适配类型

// MARK: - Constants

let kQGAGAttachmentFitTypeFitXY: AttachmentFitType = "fitXY"              // 按指定尺寸缩放
let kQGAGAttachmentFitTypeCenterFull: AttachmentFitType = "centerFull"     // 默认按资源尺寸展示，如果资源尺寸小于遮罩，则等比缩放至可填满

let kQGAGAttachmentSourceTypeTextStr: AttachmentSourceType = "textStr"     // 文字
let kQGAGAttachmentSourceTypeImgUrl: AttachmentSourceType = "imgUrl"       // 图片
let kQGAGAttachmentSourceTypeText: AttachmentSourceType = "txt"             // 文字
let kQGAGAttachmentSourceTypeImg: AttachmentSourceType = "img"             // 图片

let QGAGAttachmentSourceLoadTypeLocal: AttachmentSourceLoadType = "local"
let QGAGAttachmentSourceLoadTypeNet: AttachmentSourceLoadType = "net"

let kQGAGAttachmentSourceStyleBoldText: AttachmentSourceStyle = "b"         // 粗体

// MARK: - PCVAPConfigModel

/// VAP 配置模型
public class PCVAPConfigModel {
    public var info: VAPCommonInfo?
    public var resources: [VAPSourceInfo] = []
    public var mergedConfig: [Int: [VAPMergedInfo]] = [:]  // 帧索引 -> 融合信息数组
    
    public init() {}
}

// MARK: - VAPCommonInfo

/// VAP 通用信息
public class VAPCommonInfo {
    public var version: Int = 0
    public var framesCount: Int = 0
    public var size: CGSize = .zero
    public var videoSize: CGSize = .zero
    public var targetOrientaion: VAPOrientation = .none
    public var fps: Int = 0
    public var isMerged: Bool = false
    public var alphaAreaRect: CGRect = .zero
    public var rgbAreaRect: CGRect = .zero
    
    public init() {}
}

// MARK: - VAPSourceInfo

/// VAP 资源信息
public class VAPSourceInfo {
    // 原始信息
    public var type: AttachmentSourceType = ""
    public var loadType: AttachmentSourceLoadType = ""
    public var contentTag: String = ""
    /// 占位 tag 的融合值，可为 String（文案/URL）或 UIImage 等，由 vap_contentForTag 返回并写入
    public var contentTagValue: Any?
    public var color: UIColor?
    public var style: AttachmentSourceStyle = ""
    public var size: CGSize = .zero
    public var fitType: AttachmentFitType = ""
    
    // 加载内容
    public var sourceImage: UIImage?
    public var texture: MTLTexture?
    public var colorParamsBuffer: MTLBuffer?
    
    public init() {}
}

// MARK: - PCVAPSourceDisplayItem

/// VAP 资源显示项
public class PCVAPSourceDisplayItem {
    public var frame: CGRect = .zero
    public var sourceInfo: VAPSourceInfo?
    
    public init() {}
}

// MARK: - VAPMergedInfo

/// VAP 融合信息
public class VAPMergedInfo {
    public var source: VAPSourceInfo?
    public var renderIndex: Int = 0
    public var renderRect: CGRect = .zero
    public var needMask: Bool = false
    public var maskRect: CGRect = .zero
    public var maskRotation: Int = 0
    
    public init() {}
    
    /// 生成顶点缓冲区
    /// - Parameters:
    ///   - size: 容器大小
    ///   - maskContainerSize: 遮罩容器大小
    ///   - device: Metal 设备
    /// - Returns: 顶点缓冲区
    public func vertexBuffer(containerSize size: CGSize, maskContainerSize mSize: CGSize, device: MTLDevice) -> MTLBuffer? {
        if size.width <= 0 || size.height <= 0 || mSize.width <= 0 || mSize.height <= 0 {
            PCVAPError(kPCVAPModuleCommon, "vertexBufferWithContainerSize size error! :\(size) - \(mSize)")
            assertionFailure("vertexBufferWithContainerSize size error!")
            return nil
        }
        
        let columnCountForVertices = 4
        let columnCountForCoordinate = 2
        let vertexDataLength = 32
        
        var vertices: [Float] = Array(repeating: 0, count: 16)
        var maskCoordinates: [Float] = Array(repeating: 0, count: 8)
        var sourceCoordinates: [Float] = Array(repeating: 0, count: 8)
        
        genMTLVertices(renderRect, containerSize: size, vertices: &vertices, reverse: false)
        genMTLTextureCoordinates(maskRect, containerSize: mSize, coordinates: &maskCoordinates, reverse: true, degree: maskRotation)
        
        if let source = source, source.fitType == kQGAGAttachmentFitTypeCenterFull {
            let sourceRect = vapRectForCenterFull(source.size, renderRect.size)
            let sourceSize = vapSourceSizeForCenterFull(source.size, renderRect.size)
            genMTLTextureCoordinates(sourceRect, containerSize: sourceSize, coordinates: &sourceCoordinates, reverse: false, degree: 0)
        } else {
            sourceCoordinates = Array(kVAPMTLTextureCoordinatesIdentity)
        }
        
        var vertexData: [Float] = Array(repeating: 0, count: vertexDataLength)
        var indexForVertexData = 0
        
        // 顶点数据 + 纹理坐标 + 遮罩纹理坐标
        for i in 0..<16 {
            vertexData[indexForVertexData] = vertices[i]
            indexForVertexData += 1
            
            if i % columnCountForVertices == columnCountForVertices - 1 {
                let row = i / columnCountForVertices
                vertexData[indexForVertexData] = sourceCoordinates[row * columnCountForCoordinate]
                indexForVertexData += 1
                vertexData[indexForVertexData] = sourceCoordinates[row * columnCountForCoordinate + 1]
                indexForVertexData += 1
                vertexData[indexForVertexData] = maskCoordinates[row * columnCountForCoordinate]
                indexForVertexData += 1
                vertexData[indexForVertexData] = maskCoordinates[row * columnCountForCoordinate + 1]
                indexForVertexData += 1
            }
        }
        
        let allocationSize = vertexDataLength * MemoryLayout<Float>.size
        return device.makeBuffer(bytes: vertexData, length: allocationSize, options: kDefaultMTLResourceOption)
    }
}

