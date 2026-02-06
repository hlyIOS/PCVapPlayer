//
//  PCVapDownloadHelper.swift
//  PCVapPlayer
//
//  VAP 动画下载与缓存，参考 QGMP4DownloadHelper 逻辑
//  无外部模块依赖，可独立放入远程仓库
//

import Foundation
import CryptoKit

/// VAP/MP4 动画下载辅助类：支持远程 URL 下载、本地缓存、去重
public final class PCVapDownloadHelper {

    public static let shared = PCVapDownloadHelper()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.pcvap.download", attributes: .concurrent)
    private var completionMap: [String: [(String) -> Void]] = [:]
    private var failureMap: [String: [(Error) -> Void]] = [:]

    private init() {}

    /// 下载 VAP 资源，若已缓存则直接返回本地路径
    /// - Parameters:
    ///   - url: 远程 URL 或本地 file URL
    ///   - completion: 成功时返回本地文件路径
    ///   - failure: 失败回调
    public func download(
        url: URL,
        completion: @escaping (String) -> Void,
        failure: ((Error) -> Void)? = nil
    ) {
        // 本地 file URL 直接返回路径
        if url.isFileURL {
            let path = url.path
            if fileManager.fileExists(atPath: path) {
                DispatchQueue.main.async { completion(path) }
            } else {
                DispatchQueue.main.async { failure?(NSError(domain: "PCVapDownloadHelper", code: -1, userInfo: [NSLocalizedDescriptionKey: "Local file not found"])) }
            }
            return
        }

        let cacheKey = cacheKey(for: url)
        let filePath = cacheFilepath(for: url)

        // 已缓存则直接回调
        if fileManager.fileExists(atPath: filePath) {
            DispatchQueue.main.async { completion(filePath) }
            return
        }

        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            if let f = failure {
                if self.failureMap[cacheKey] != nil {
                    self.failureMap[cacheKey]?.append(f)
                } else {
                    self.failureMap[cacheKey] = [f]
                }
            }
            if self.completionMap[cacheKey] != nil {
                self.completionMap[cacheKey]?.append(completion)
                return
            }
            self.completionMap[cacheKey] = [completion]
        }

        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        session.downloadTask(with: request) { [weak self] location, _, error in
            guard let self else { return }
            if let error {
                self.executeFailure(cacheKey: cacheKey, error: error)
                return
            }
            guard let location else {
                self.executeFailure(cacheKey: cacheKey, error: NSError(domain: "PCVapDownloadHelper", code: -2, userInfo: [NSLocalizedDescriptionKey: "Download location is nil"]))
                return
            }
            let cacheDir = self.cacheDirectory(cacheKey: cacheKey)
            if !self.fileManager.fileExists(atPath: cacheDir) {
                try? self.fileManager.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
            }
            let destURL = URL(fileURLWithPath: filePath)
            do {
                if self.fileManager.fileExists(atPath: filePath) {
                    try self.fileManager.removeItem(atPath: filePath)
                }
                try self.fileManager.moveItem(at: location, to: destURL)
                self.executeCompletion(cacheKey: cacheKey, filePath: filePath)
            } catch {
                self.executeFailure(cacheKey: cacheKey, error: error)
            }
        }.resume()
    }

    // MARK: - Private

    private func executeCompletion(cacheKey: String, filePath: String) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            let blocks = self.completionMap.removeValue(forKey: cacheKey) ?? []
            DispatchQueue.main.async {
                blocks.forEach { $0(filePath) }
            }
        }
    }

    private func executeFailure(cacheKey: String, error: Error) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            let blocks = self.failureMap.removeValue(forKey: cacheKey) ?? []
            self.completionMap.removeValue(forKey: cacheKey)
            DispatchQueue.main.async {
                blocks.forEach { $0(error) }
            }
        }
    }

    private func cacheDirectory(cacheKey: String) -> String {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory()
        return "\(caches)/mp4/\(cacheKey)"
    }

    private func cacheFilepath(for url: URL) -> String {
        let key = cacheKey(for: url)
        let dir = cacheDirectory(cacheKey: key)
        let name = url.lastPathComponent.isEmpty ? "vap.mp4" : url.lastPathComponent
        return "\(dir)/\(name)"
    }

    private func cacheKey(for url: URL) -> String {
        let data = url.absoluteString.data(using: .utf8) ?? Data()
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
