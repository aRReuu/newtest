//
//  ImiCloudBackupManager.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 10/1/25.
//  实现将本地数据库文件夹导出到iCloud Drive

import UIKit
import Foundation
import MobileCoreServices
import UniformTypeIdentifiers

final class ImiCloudBackupManager: NSObject, UIDocumentPickerDelegate {

    static let shared = ImiCloudBackupManager()

    // 备份在本地的源文件夹名称
    private let sourceFolderName = "ImpressDB"
    
    // 用于存储上次导出时间的Key
    private let lastBackupTimeKey = "ImLastiCloudBackupTime"
    
    // 备份时间间隔（72小时）
    private let backupIntervalSeconds: TimeInterval = 72 * 60 * 60
    
    // 用于处理文件选择器回调的闭包
    private var pendingCompletion: ((Error?) -> Void)?

    // MARK: - 1. 时间检查
    
    /// 检查是否应该导出备份
    /// - Returns: 如果超过backupIntervalSeconds小时，返回true；否则返回false
    func shouldPerformBackup() -> Bool {
        guard let lastBackupTime = UserDefaults.standard.object(forKey: lastBackupTimeKey) as? TimeInterval else {
            // 从未备份过，应该导出
            return true
        }
        
        let timeSinceLastBackup = Date().timeIntervalSince1970 - lastBackupTime
        let shouldBackup = timeSinceLastBackup >= backupIntervalSeconds
        
        zcLog("上次导出至今: \(timeSinceLastBackup / 3600) 小时，是否需要导出: \(shouldBackup)")
        return shouldBackup
    }
    
    /// 更新上次导出时间为当前时间
    private func updateLastBackupTime() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastBackupTimeKey)
        UserDefaults.standard.synchronize()
    }

    // MARK: - 2. 导出逻辑检查
    
    /// 检查是否需要导出，如需要则显示提醒
    /// - Parameters:
    ///   - presenter: 用于呈现UIDocumentPickerViewController的视图控制器
    ///   - completion: 完成回调（不执行实际导出，仅检查时间）
    func checkAndNotifyIfNeeded(from presenter: UIViewController, completion: @escaping (Error?) -> Void) {
        // 检查时间间隔
        guard shouldPerformBackup() else {
            zcLog("导出间隔未超过设定备份间隔，跳过提醒")
            completion(nil)
            return
        }
        
        // 如果需要导出，显示提醒对话框
        DispatchQueue.main.async {
            ImAlertController.alert(message: "记得手动备份数据.", buttons: alertDescription) {[weak self] (result) in
                if case .ok = result{
                    // 更新上次导出时间
                    self?.updateLastBackupTime()
                }
            }
        }
    }

    // MARK: - 3. 手动导出
    
    /// 手动触发导出，显示文件选择器
    /// - Parameters:
    ///   - presenter: 用于呈现UIDocumentPickerViewController的视图控制器
    ///   - completion: 完成回调
    func performManualExport(from presenter: UIViewController, completion: @escaping (Error?) -> Void) {
        // 先检查源文件夹是否存在
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            let err = NSError(domain: "ImiCloudBackupManager", 
                            code: -1, 
                            userInfo: [NSLocalizedDescriptionKey: "无法获取Documents目录"])
            completion(err)
            return
        }
        
        let sourceURL = documentsURL.appendingPathComponent(sourceFolderName)
        
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            let err = NSError(domain: "ImiCloudBackupManager", 
                            code: -2, 
                            userInfo: [NSLocalizedDescriptionKey: "本地ImpressDB文件夹不存在"])
            zcLog("源文件夹不存在: \(sourceURL.path)")
            completion(err)
            return
        }
        
        presentDocumentPicker(from: presenter, completion: completion)
    }
    
    // MARK: - 4. 文件选择器
    
    /// 呈现iCloud Drive选择器
    private func presentDocumentPicker(from presenter: UIViewController, completion: @escaping (Error?) -> Void) {
        let documentPicker: UIDocumentPickerViewController
        
        if #available(iOS 14.0, *) {
            documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
        } else {
            documentPicker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
        }
        
        documentPicker.delegate = self
        self.pendingCompletion = completion
        presenter.present(documentPicker, animated: true, completion: nil)
    }
    
    // MARK: - 5. UIDocumentPickerDelegate
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let destinationURL = urls.first else {
            self.pendingCompletion?(nil)
            self.pendingCompletion = nil
            return
        }
        
        // 后台执行导出操作
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var didStartAccess = false
            defer {
                if didStartAccess {
                    destinationURL.stopAccessingSecurityScopedResource()
                }
            }
            
            // 开始安全访问
            guard destinationURL.startAccessingSecurityScopedResource() else {
                let err = NSError(domain: "ImiCloudBackupManager", 
                                code: -3, 
                                userInfo: [NSLocalizedDescriptionKey: "无法访问所选文件夹，请检查权限"])
                zcLog("无法开始安全访问")
                DispatchQueue.main.async {
                    self.pendingCompletion?(err)
                    self.pendingCompletion = nil
                }
                return
            }
            didStartAccess = true
            
            // 执行导出
            self.exportDatabase(from: destinationURL) { [weak self] error in
                if error == nil {
                    // 导出成功，更新时间戳
                    self?.updateLastBackupTime()
                    zcLog("数据库导出成功")
                } else {
                    zcLog("数据库导出失败: \(error?.localizedDescription ?? "未知错误")")
                }
                DispatchQueue.main.async {
                    self?.pendingCompletion?(error)
                    self?.pendingCompletion = nil
                }
            }
        }
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.pendingCompletion?(nil)
        self.pendingCompletion = nil
    }
    
    // MARK: - 6. 实际导出逻辑
    
    /// 执行导出操作
    /// - Parameters:
    ///   - destinationURL: iCloud Drive目标文件夹URL
    ///   - completion: 完成回调
    private func exportDatabase(from destinationURL: URL, completion: @escaping (Error?) -> Void) {
        let fileManager = FileManager.default
        
        // 获取本地ImpressDB文件夹
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            let err = NSError(domain: "ImiCloudBackupManager", 
                            code: -4, 
                            userInfo: [NSLocalizedDescriptionKey: "无法获取Documents目录"])
            completion(err)
            return
        }
        
        let sourceURL = documentsURL.appendingPathComponent(sourceFolderName)
        
        // 检查源文件夹是否存在
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            let err = NSError(domain: "ImiCloudBackupManager", 
                            code: -5, 
                            userInfo: [NSLocalizedDescriptionKey: "本地ImpressDB文件夹不存在"])
            completion(err)
            return
        }
        
        // 目标路径：iCloud Drive/选定文件夹/ImpressDB_Backup_日期时间
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH_mm_ss"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX") // 使用固定locale避免时区问题
        dateFormatter.timeZone = TimeZone.current // 使用用户当前时区
        let timestamp = dateFormatter.string(from: Date())
        // P0-0: backups always use unique new names, never delete or
        // replace any existing folder in the selected cloud directory.
        let backupFolderName = "ImpressDB_Backup_\(timestamp)_\(UUID().uuidString.prefix(8))"
        let targetURL = destinationURL.appendingPathComponent(backupFolderName)

        do {
            guard !fileManager.fileExists(atPath: targetURL.path) else {
                throw NSError(domain: "ImiCloudBackupManager", code: -31,
                              userInfo: [NSLocalizedDescriptionKey: "备份目标已存在，安全模式禁止覆盖"])
            }
            // 拷贝ImpressDB文件夹到新位置；永不修改已有目标
            try fileManager.copyItem(at: sourceURL, to: targetURL)
            zcLog("数据库导出成功: \(targetURL.path)")
            completion(nil)
            
        } catch let error as NSError {
            // 处理特定的文件操作错误
            let userError = NSError(domain: "ImiCloudBackupManager", 
                                   code: error.code, 
                                   userInfo: [NSLocalizedDescriptionKey: "导出失败: \(error.localizedDescription)"])
            completion(userError)
        }
    }
}
