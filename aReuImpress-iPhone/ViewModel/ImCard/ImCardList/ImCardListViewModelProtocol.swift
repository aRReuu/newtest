//
//  ImCardListViewModelProtocol.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 11/1/24.
//

import Foundation
import Combine

protocol ImCardListViewModelProtocol {
    // MARK: - Publishers
    var itemsPublisher: AnyPublisher<[ImCardModel], Never> { get }
    var filterCardsPublisher: AnyPublisher<[ImCardModel], Never> { get }
    var isFilterPublisher: AnyPublisher<Bool, Never> { get }
    
    // MARK: - Properties
    var itemCount: Int { get }
    
    // TODO: 这是什么东西? 为什么初始化出现在协议里面,下次看到必须修复,不能这样写!
    init()
    
    // MARK: - Methods
    func fetchCards()
    func getItem(at index: Int) -> ImCardModel?
    func getChat(at index: Int) -> ImCardModel?
    func indexPath(for item: ImCardModel) -> IndexPath?
    
    func createNewCard(question: String, answer: String) -> ImCardModel
    
    func updateStatusInFilter()
    func predicateCardSeriesDatas(filterText: String?)
    
    func insertItem(_ item: ImCardModel) throws
    func updateItem(_ item: ImCardModel) throws
    func deleteItem(at index: Int) throws
}
