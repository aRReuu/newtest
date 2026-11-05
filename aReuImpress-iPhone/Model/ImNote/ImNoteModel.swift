//
//  ImNoteModel.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 12/9/22.
//


import WCDBSwift

struct ImNoteModel: TableCodable
{
    /// 主键
    var identifier:Int?
    
    /// 笔记标题
    var mainTitle: String?
    
    /// 笔记内容
    var markdownText: String?
    
    /// 创建时间
    var createTime:Date?
    
    /// 笔记文件最后修改时间
    var modificationDate:Date?
    
    /// 文件的目录层级路径
    var directoryPath: String?
    
    
    enum CodingKeys: String, CodingTableKey {
        typealias Root = ImNoteModel
        static let objectRelationalMapping = TableBinding(CodingKeys.self)
        case identifier = "id"
        case mainTitle
        case createTime
        case markdownText
        case modificationDate = "modify_date"
        case directoryPath = "directory_path"
        
        static var columnConstraintBindings: [CodingKeys: ColumnConstraintBinding]? {
            return [
                .identifier: ColumnConstraintBinding(isPrimary: true,
                                                     isAutoIncrement: true)
            ]
        }
    }
}
