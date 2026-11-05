//
//  ImDBHandler.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 12/28/22.
//

import WCDBSwift
import Combine


/// 桥接数据库类
final class ImDBHandler
{
    /// db sharedInstance
    static let share = ImDBHandler()
    
    /// lazy database
    lazy private var imDatabase:Database = {
        let path = documentPath + "/" + dbName
        let db = Database(withPath: path)
        return db
    }()
    
    
    
    
    
    
    // MARK: - BaseFunction
    
    /// 判断数据库是否开启
    /// - Returns: <#description#>
    func isOpen() -> Bool
    {
        return imDatabase.isOpened
    }
    
    /// 关闭数据库
    func closeDB()
    {
        guard true == imDatabase.isOpened else {zcLog("DataBase has been closed"); return}
        imDatabase.close(onClosed: {
           zcLog("close successfully!")
       })
    }
    
    /// 创建数据表
    /// A failed table creation must be reported to the scene bootstrap.
    /// Running the UI against a partially initialized database is unsafe.
    private func createTable<T: TableDecodable>(_ table: String, _ modelType: T.Type) -> Bool {
        do {
            try imDatabase.create(table: table, of: modelType)
            return true
        } catch {
            zcLog("create table \(table) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Returns false if ANY required table failed to initialize.
    /// Keep every creation attempt independent for diagnostics and recovery.
    /// Keep the notes/cards schema intact. Purge only retired LLM credentials
    /// and native-chat history, as authorized by the owner. The purge is
    /// idempotent: fresh installs have no retired tables to drop.
    /// Never log table contents, SQL statements or API credentials.
    private func purgeRetiredChatTables() -> Bool {
        let retiredTables = ["impress_llm_model", "impress_polling_chat", "impress_chat"]
        do {
            for table in retiredTables {
                if try imDatabase.isTableExists(table) {
                    try imDatabase.drop(table: table)
                }
            }
            return true
        } catch {
            zcLog("Retired credential cleanup failed; database bootstrap halted: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    public func createAllDB() -> Bool {
        guard purgeRetiredChatTables() else { return false }
        let statuses = [
            createTable(ImDBTableType.notes.description, ImNoteModel.self),
            createTable(ImDBTableType.card.description, ImCardModel.self)
        ]
        return statuses.allSatisfy { $0 }
    }

    // MARK: - Legacy-independent database operations
    /// Delete
    /// - Parameter fromTable: 表
    /// - Parameter condition: 条件
    func deleteFromTable(table: String,
                        where condition: Condition,
                        completion: @escaping (ImHandlerResult<Void>) -> Void)
    {
        loadShare.show()
        DispatchQueue.global().async {[weak self] in
            guard let self = self else {return}
            do {
                try self.imDatabase.delete(fromTable: table, where: condition)
                DispatchQueue.main.async {
                    loadShare.hide()
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    loadShare.hide()
                    // ImAlertController.warningAlert(error.localizedDescription)
                    completion(.failure(error))
                }
            }
        }
    }
}





// MARK: - iCloud Backup Check
extension ImDBHandler
{
    /// 检查是否需要导出备份到iCloud，如需要则显示提醒
    /// - Parameters:
    ///   - presenter: 用于呈现提醒对话框的视图控制器
    ///   - completion: 完成回调
    func checkBackupReminder(from presenter: UIViewController, completion: @escaping (Swift.Error?) -> Void) {
        ImiCloudBackupManager.shared.checkAndNotifyIfNeeded(from: presenter) { error in
            if let error = error {
                zcLog("Backup check failed: \(error.localizedDescription)")
            } else {
                zcLog("Backup check completed.")
            }
            completion(error)
        }
    }
}

// MARK: - ImpressDataBase-CURD
extension ImDBHandler
{
    /// 获取 WCDB 数据库占用的总磁盘空间大小
    /// - Parameter database: WCDB 的 Database 实例
    /// - Returns: 数据库文件及附属文件（-wal, -shm）的总大小（字节），如果失败则返回 nil
    func getDatabaseSize() -> String?
    {
        let path = imDatabase.path
        let walPath = path + "-wal" // Write-Ahead Logging 文件
        let shmPath = path + "-shm" // Shared Memory 文件
        let filePaths = [path, walPath, shmPath]
        let fileManager = FileManager.default
        var totalSize: Int64 = 0
        
        do {
            for filePath in filePaths {
                if fileManager.fileExists(atPath: filePath) {
                    // 获取文件属性
                    let attributes = try fileManager.attributesOfItem(atPath: filePath)
                    // 从属性字典中获取文件大小
                    if let fileSize = attributes[.size] as? NSNumber {
                        totalSize += fileSize.int64Value
                    }
                }
            }
            let sizeInMB = Double(totalSize) / (1024 * 1024)
            return String(format: "%.2f MB", sizeInMB)
        } catch {
            zcLog("获取数据库大小失败: \(error)")
            return nil
        }
    }
    
    
    /// Create model
    func insertToDB<T: TableEncodable>(intoTable table: String,
                                       with objects: [T],
                                       completion: ((ImHandlerResult<Void>) -> Void)? = nil)
    {
        loadShare.show()
        DispatchQueue.global().async {[weak self] in
            guard let self = self else {return}
            do {
                try self.imDatabase.insert(objects: objects, intoTable: table)
                DispatchQueue.main.async {
                    loadShare.hide()
                    completion?(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    loadShare.hide()
                    // ImAlertController.warningAlert(error.localizedDescription)
                    completion?(.failure(error))
                }
            }
        }
    }

    
    
    
    /// Update
    func updateToDB<T: TableEncodable>(table: String,
                                      on propertys: [PropertyConvertible],
                                      with object: T,
                                      where condition: Condition? = nil,
                                      completion: @escaping (ImHandlerResult<Void>) -> Void)
    {
        loadShare.show()
        DispatchQueue.global().async {[weak self] in
            guard let self = self else {return}
            do {
                try self.imDatabase.update(table: table,
                                         on: propertys,
                                         with: object,
                                         where: condition)
                DispatchQueue.main.async {
                    loadShare.hide()
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    loadShare.hide()
                    // ImAlertController.warningAlert(error.localizedDescription)
                    completion(.failure(error))
                }
            }
        }
    }
    
    /// 异步并发查询指定数据集合
    func queryFromDB<T: TableDecodable>(table: String,
                                       on: [PropertyConvertible]? = nil,
                                       cls clsName: T.Type,
                                       where condition: Condition? = nil,
                                       orderBy orderList: [OrderBy]? = nil,
                                       limit: Limit? = nil,
                                       completion: @escaping (ImHandlerResult<[T]>) -> Void)
    {
        loadShare.show()
        DispatchQueue.global().async {[weak self] in
            guard let self = self else {return}
            do {
                let objects: [T]
                if let onProperty = on {
                    objects = try self.imDatabase.getObjects(on: onProperty,
                                                           fromTable: table,
                                                           where: condition,
                                                           orderBy: orderList,
                                                           limit: limit)
                } else {
                    objects = try self.imDatabase.getObjects(fromTable: table,
                                                           where: condition,
                                                           orderBy: orderList,
                                                           limit: limit)
                }
                DispatchQueue.main.async {
                    loadShare.hide()
                    completion(.success(objects))
                }
            } catch {
                DispatchQueue.main.async {
                    loadShare.hide()
                    // ImAlertController.warningAlert(error.localizedDescription)
                    completion(.failure(error))
                }
            }
        }
    }
    
    /// 返回单个查询模型数据
    func queryOneObjectFromDB<T: TableDecodable>(table: String,
                                                cls clsName: T.Type,
                                                where condition: Condition? = nil,
                                                offSet:Offset? = nil,
                                                completion: @escaping (ImHandlerResult<T>) -> Void)
    {
        loadShare.show()
        DispatchQueue.global().async {[weak self] in
            guard let self = self else {return}
            do {
                if let model: T = try self.imDatabase.getObject(fromTable: table,
                                                                where: condition,
                                                                offset: offSet) {
                    DispatchQueue.main.async {
                        loadShare.hide()
                        completion(.success(model))
                    }
                } else {
                    DispatchQueue.main.async {
                        loadShare.hide()
                        let error = NSError(domain: "Database",
                                            code: -1,
                                            userInfo: [NSLocalizedDescriptionKey: "Can't found any object."])
                        // ImAlertController.warningAlert(error.localizedDescription)
                        completion(.failure(error))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    loadShare.hide()
                    completion(.failure(error))
                }
            }
        }
    }
    
    /// 返回指定属性行数
    /// Count with SQL COUNT(*) instead of fetching every matching row.
    /// Background counts must not display a global loading overlay.
    func getRows(table: String,
                 where condition: Condition? = nil,
                 completion: @escaping (ImHandlerResult<Int>) -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "ImpressDB", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Database handler unavailable"])))
                }
                return
            }
            let result: ImHandlerResult<Int>
            do {
                let row = try self.imDatabase.getRow(
                    on: Column.all.count(), fromTable: table, where: condition)
                result = .success(Int(row.first?.int64Value ?? 0))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 获取指定数据表中的一条随机数据
    /// - Parameters:
    ///   - table: <#table description#>
    ///   - clsName: <#clsName description#>
    ///   - limit: 默认为获取1条数据
    ///   - condition: <#condition description#>
    ///   - completion: <#completion description#>
    /// A single random query; always completes, including when the table is empty.
    /// Do not SELECT every BLOB just to count rows before choosing a random offset.
    func queryRandomObject<T: TableDecodable>(from table: String,
                                               cls clsName: T.Type,
                                               where condition: Condition? = nil,
                                               completion: @escaping (ImHandlerResult<T>) -> Void) {
        loadShare.show()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    loadShare.hide()
                    completion(.failure(NSError(domain: "ImpressDB", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Database handler unavailable"])))
                }
                return
            }
            let result: ImHandlerResult<T>
            do {
                let order = [Order(with: Expression.function(named: "RANDOM"))]
                let matches: [T] = try self.imDatabase.getObjects(
                    fromTable: table, where: condition, orderBy: order, limit: 1)
                if let selected = matches.first {
                    result = .success(selected)
                } else {
                    result = .failure(NSError(domain: "ImpressDB", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No matching record"] ))
                }
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                loadShare.hide()
                completion(result)
            }
        }
    }

    /// 获取指定数据表中的N条随机数据
    /// - Parameters:
    ///   - n: <#n description#>
    ///   - table: <#table description#>
    ///   - clsName: <#clsName description#>
    ///   - condition: <#condition description#>
    ///   - completion: <#completion description#>
    func queryRandomObjects<T: TableDecodable>(ofCount n: Int,
                                               fromTable table: String,
                                               cls clsName: T.Type,
                                               where condition: Condition? = nil,
                                               completion: @escaping (ImHandlerResult<[T]>) -> Void)
    {
        if n <= 0 { DispatchQueue.main.async { completion(.success([])) }; return }
        //
        loadShare.show()
        DispatchQueue.global().async {[weak self] in
            guard let self = self else {return}
            do {
                let orderBy = [Order(with:Expression.function(named: "RANDOM"))]
                let results: [T] = try self.imDatabase.getObjects(fromTable: table,
                                                                  where: condition,
                                                                  orderBy: orderBy,
                                                                  limit: n)
                DispatchQueue.main.async {
                    loadShare.hide()
                    completion(.success(results))
                }
                
            } catch {
                DispatchQueue.main.async {
                    loadShare.hide()
                    // ImAlertController.warningAlert(error.localizedDescription)
                    completion(.failure(error))
                }
            }
        }
    }
}
