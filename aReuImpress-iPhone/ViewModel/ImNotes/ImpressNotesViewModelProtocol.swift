//
//  ImpressNotesViewModelProtocol.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 5/19/25.
//  NoteViewModel代码架构分层

import Foundation
import Combine

typealias ImNotesViewModelProtocol =
    NotesViewModelDatesProtocol &
    NotesViewModelLogicProtocol &
    ImNotesCombineProtocol

// MARK: - Combine Publisher 协议
protocol ImNotesCombineProtocol
{
    /// `notes` 数据源的发布者
    var notesPublisher: AnyPublisher<[ImNoteModel], Never> { get }
    
    /// `filteredNotes` 数据源的发布者
    var filteredNotesPublisher: AnyPublisher<[ImNoteModel], Never> { get }
    
    /// `isFiltering` 状态的发布者
    var isFilteringPublisher: AnyPublisher<Bool, Never> { get }
    
    /// 一次性事件的发布者
    var actionPublisher: AnyPublisher<BaseActionResult, Never> { get }
}


protocol NotesViewModelDatesProtocol: ImBaseProtocol
{
    ///
    var currentNotesCount:Int { get }

    /// 获取指定笔记
    func getCurrentNote(indexPath:IndexPath) -> ImNoteModel?
    
    /// 获取指定笔记主键对应的indexPath
    func indexPath(for selectedNoteID: Int) -> IndexPath?
}

protocol NotesViewModelLogicProtocol
{
    func fetchNotes(by vc:ImBaseViewController)
    
    func predicateNoteSeriesDatas(filtterText:String)
    
    func updateStatusInFliter()
    
    func deleteNote(at indexPath: IndexPath)
}


// MARK: - 新增操作结果枚举
enum NotesCoordinateResult
{
    case reloadData
    case delete(index: IndexPath)
    case updateChat(note:ImNoteModel)
}
