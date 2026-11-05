//
//  aReuImpress_iPhoneTests.swift
//  aReuImpress-iPhoneTests
//
//  Created by aReu on 12/22/24.
//

import XCTest

//// MARK: 在scheme的build设定中,将所有的编译,集成等都勾选,最后成功识别
@testable import aReuImpress_iPhone


class aReuImpress_iPhoneTests: XCTestCase
{
    override func setUpWithError() throws
    {
    }

    override func tearDownWithError() throws
    {
    }

    func testExample() throws
    {
    }
    
    func testScanMarkdownFiles() throws
    {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let impressVaultURL = documentsURL.appendingPathComponent("ImpressVault")
        
        if let enumerator = fileManager.enumerator(at: impressVaultURL,
                                                 includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "md" {
                do {
                    let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                    if let modificationDate = attributes[.modificationDate] as? Date {
                        let fileName = fileURL.deletingPathExtension().lastPathComponent
                        print("文件标题: \(fileName), 最后修改时间: \(modificationDate)")
                    }
                } catch {
                    print("处理文件出错: \(fileURL.lastPathComponent), 错误: \(error.localizedDescription)")
                }
            }
        }
    }
}

