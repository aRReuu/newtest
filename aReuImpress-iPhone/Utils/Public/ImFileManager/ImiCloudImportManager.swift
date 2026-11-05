//
//  ImiCloudImportManager.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 2/2/26.
//  实现从iCloud Drive导入Obsidian文件夹到本地沙盒

import UIKit
import Foundation
import MobileCoreServices
import UniformTypeIdentifiers

final class ImiCloudImportManager: NSObject, UIDocumentPickerDelegate {

    static let shared = ImiCloudImportManager()

    // 目标文件夹名称
    private let targetFolderName = "ImpressVault"
    
    // 用于存储文件选择器回调的闭包
    private var pendingCompletion: ((Error?) -> Void)?

    // MARK: - 1. 手动导入
    
    /// 手动触发导入，显示文件选择器
    /// - Parameters:
    ///   - presenter: 用于呈现UIDocumentPickerViewController的视图控制器
    ///   - completion: 完成回调
    func performManualImport(from presenter: UIViewController, completion: @escaping (Error?) -> Void) {
        presentDocumentPicker(from: presenter, completion: completion)
    }
    
    // MARK: - 2. 文件选择器
    
    /// 呈现iCloud Drive选择器
    private func presentDocumentPicker(from presenter: UIViewController, completion: @escaping (Error?) -> Void) {
        let documentPicker: UIDocumentPickerViewController
        
        if #available(iOS 14.0, *) {
            // 使用 .folder 类型，只允许选择文件夹
            documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
        } else {
            // iOS 14 以下使用 public.folder 类型
            documentPicker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
        }
        
        documentPicker.delegate = self
        documentPicker.allowsMultipleSelection = false
        self.pendingCompletion = completion
        presenter.present(documentPicker, animated: true, completion: nil)
        zcLog("已弹出文件选择器 - 请选择Obsidian文件夹")
    }
    
    // MARK: - 3. UIDocumentPickerDelegate
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        zcLog("documentPicker 回调被触发，选中 \(urls.count) 个文件")
        
        guard let sourceURL = urls.first else {
            zcLog("没有获取到URL")
            self.pendingCompletion?(NSError(
                domain: "ImiCloudImportManager", code: -30,
                userInfo: [NSLocalizedDescriptionKey: "未选择任何文件夹，未执行导入。"]))
            self.pendingCompletion = nil
            return
        }
        
        zcLog("选中的路径: \(sourceURL.path)")
        zcLog("是否为安全域资源: \(sourceURL.isFileURL)")
        
        // 后台执行导入操作
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var didStartAccess = false
            defer {
                if didStartAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                    zcLog("停止安全访问")
                }
            }
            
            // 开始安全访问 - TrollStore 安装的应用可能无法正常获取安全域访问权限
            let accessGranted = sourceURL.startAccessingSecurityScopedResource()
            zcLog("安全域访问结果: \(accessGranted)")
            
            // 授权失败一律停止，禁止绕过 iOS File Provider 的安全访问策略
            if accessGranted {
                didStartAccess = true
                zcLog("成功开始安全访问")
            } else {
                let error = NSError(domain: "ImiCloudImportManager", code: -9,
                    userInfo: [NSLocalizedDescriptionKey:
                        "未取得文件夹安全访问授权。原有笔记保持不变；请重新选择文件夹。"])
                DispatchQueue.main.async {
                    self.pendingCompletion?(error)
                    self.pendingCompletion = nil
                }
                return
            }
            
            // 检查是否是文件夹
            var isDirectory: ObjCBool = false
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
                let err = NSError(domain: "ImiCloudImportManager",
                                code: -5,
                                userInfo: [NSLocalizedDescriptionKey: "所选路径不存在"])
                zcLog("路径不存在")
                DispatchQueue.main.async {
                    self.pendingCompletion?(err)
                    self.pendingCompletion = nil
                }
                return
            }
            
            if !isDirectory.boolValue {
                let err = NSError(domain: "ImiCloudImportManager",
                                code: -6,
                                userInfo: [NSLocalizedDescriptionKey: "请选择一个文件夹，而不是文件"])
                zcLog("用户选择了文件而不是文件夹")
                DispatchQueue.main.async {
                    self.pendingCompletion?(err)
                    self.pendingCompletion = nil
                }
                return
            }
            
            zcLog("确认是文件夹，开始导入")
            
            // 执行导入
            self.importFolder(from: sourceURL) { [weak self] error in
                if error == nil {
                    zcLog("文件夹导入成功")
                } else {
                    zcLog("文件夹导入失败: \(error?.localizedDescription ?? "未知错误")")
                }
                DispatchQueue.main.async {
                    self?.pendingCompletion?(error)
                    self?.pendingCompletion = nil
                }
            }
        }
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // A cancelled picker is NOT a successful import.
        self.pendingCompletion?(NSError(
            domain: "ImiCloudImportManager", code: -30,
            userInfo: [NSLocalizedDescriptionKey: "已取消导入，现有笔记未被修改。"]))
        self.pendingCompletion = nil
    }
    
    // MARK: - 4. 实际导入逻辑
    
    /// 执行导入操作
    /// - Parameters:
    ///   - sourceURL: iCloud Drive源文件夹URL
    ///   - completion: 完成回调
    private func importFolder(from sourceURL: URL, completion: @escaping (Error?) -> Void) {
        let fileManager = FileManager.default
        
        // 获取本地Documents目录
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            let err = NSError(domain: "ImiCloudImportManager", 
                            code: -4, 
                            userInfo: [NSLocalizedDescriptionKey: "无法获取Documents目录"])
            completion(err)
            return
        }
        
        let targetURL = documentsURL.appendingPathComponent(targetFolderName)
        zcLog("目标路径: \(targetURL.path)")
        
        do {
            // 检查源文件夹是否可读（TrollStore 环境可能需要额外检查）
            guard fileManager.isReadableFile(atPath: sourceURL.path) else {
                let err = NSError(domain: "ImiCloudImportManager",
                                code: -7,
                                userInfo: [NSLocalizedDescriptionKey: "无法读取源文件夹。提示：如果是 iCloud 文件夹，请确保文件已下载到本地（显示为已下载状态，而非仅云端）"])
                zcLog("源文件夹不可读: \(sourceURL.path)")
                completion(err)
                return
            }
            
            // P0-0: never remove or replace a previously imported Vault.
            // Copy into a unique private staging directory, then move only if
            // the destination is still absent. This is NOT two-way sync.
            try ImVaultSafeImporter.copyOnlyWhenAbsent(
                from: sourceURL, to: targetURL, fileManager: fileManager)

            // 验证拷贝结果
            if fileManager.fileExists(atPath: targetURL.path) {
                // 统计文件数量
                if let contents = try? fileManager.contentsOfDirectory(atPath: targetURL.path) {
                    zcLog("文件夹导入成功: \(targetURL.path)，包含 \(contents.count) 个顶层项目")
                } else {
                    zcLog("文件夹导入成功: \(targetURL.path)")
                }
                completion(nil)
            } else {
                let err = NSError(domain: "ImiCloudImportManager",
                                code: -8,
                                userInfo: [NSLocalizedDescriptionKey: "拷贝完成但目标文件夹不存在"])
                completion(err)
            }
            
        } catch let error as NSError {
            zcLog("导入失败，错误码: \(error.code)，描述: \(error.localizedDescription)")
            
            // 根据错误码提供更友好的提示
            var errorMessage = "导入失败: \(error.localizedDescription)"
            switch error.code {
            case 257: // NSFileReadNoPermissionError
                errorMessage = "没有权限访问源文件夹。\n\n提示：\n1. 请确保选择的是本地文件夹，而非仅存储在 iCloud 云端的文件夹\n2. 如果是 TrollStore 安装，可能需要先打开一次官方 Obsidian App 确保文件已同步到本地"
            case 260: // NSFileReadNoSuchFileError
                errorMessage = "源文件夹不存在或无法访问"
            case 512: // NSFileWriteUnknownError
                errorMessage = "写入失败，可能是磁盘空间不足"
            default:
                break
            }
            
            let userError = NSError(domain: "ImiCloudImportManager", 
                                   code: error.code, 
                                   userInfo: [NSLocalizedDescriptionKey: errorMessage])
            completion(userError)
        }
    }
}
    
/// Legacy one-time sandbox import: NO OVERWRITE under any circumstances.
/// Does not touch the source and does not allow merging user-controlled data.
enum ImVaultSafeImporter {
    static func copyOnlyWhenAbsent(from sourceURL: URL, to destinationURL: URL,
                                   fileManager: FileManager = .default) throws {
        let destination = destinationURL.standardizedFileURL
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw NSError(domain: "ImVaultSafeImporter", code: -31,
                          userInfo: [NSLocalizedDescriptionKey:
                            "已存在本地 Vault。安全模式禁止覆盖导入；请使用只读连接功能。"])
        }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".impress-vault-import-" + UUID().uuidString, isDirectory: true)
        defer {
            // Only clean up our unique transient staging path; never the Vault.
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
        }
        try fileManager.copyItem(at: sourceURL, to: staging)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw NSError(domain: "ImVaultSafeImporter", code: -32,
                          userInfo: [NSLocalizedDescriptionKey:
                            "导入过程中目标 Vault 已存在，已停止以避免覆盖。"])
        }
        try fileManager.moveItem(at: staging, to: destination)
    }
}
