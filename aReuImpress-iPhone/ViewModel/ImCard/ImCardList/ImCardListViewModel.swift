import Foundation
import Combine
import WCDBSwift

/// 卡片列表视图模型
class ImCardListViewModel: ObservableObject, ImCardListViewModelProtocol {

    @Published private var items: [ImCardModel] = []
    @Published private var filterCards: [ImCardModel] = []
    @Published private var isFilter: Bool = false
    private var filterText: String? = nil

    var itemsPublisher: AnyPublisher<[ImCardModel], Never> { $items.eraseToAnyPublisher() }
    var filterCardsPublisher: AnyPublisher<[ImCardModel], Never> { $filterCards.eraseToAnyPublisher() }
    var isFilterPublisher: AnyPublisher<Bool, Never> { $isFilter.eraseToAnyPublisher() }

    private var currentCards: [ImCardModel] {
        isFilter ? filterCards : items
    }

    var itemCount: Int {
        currentCards.count
    }

    private var cancellables = Set<AnyCancellable>()

    required init() {
        setupBindings()
    }

    private func setupBindings() {
        // 过滤状态变更时更新过滤后的卡片
        isFilterPublisher
            .combineLatest(filterCardsPublisher)
            .receive(on: DispatchQueue.main)
            .sink { _, _ in
                // Trigger reload in view controller
            }
            .store(in: &cancellables)
    }

    // MARK: - Protocol Implementation
    func getItem(at index: Int) -> ImCardModel? {
        guard index >= 0 && index < currentCards.count else { return nil }
        return currentCards[index]
    }

    func getChat(at index: Int) -> ImCardModel? {
        return getItem(at: index)
    }

    func indexPath(for item: ImCardModel) -> IndexPath? {
        guard let index = currentCards.firstIndex(where: { $0.identifier == item.identifier }) else { return nil }
        return IndexPath(row: 0, section: index)
    }

    func insertItem(_ item: ImCardModel) throws {
        let tableName = ImDBTableType.card.description
        dbShare.insertToDB(intoTable: tableName, with: [item]) { [weak self] (result) in
            switch result {
            case .success():
                self?.items.insert(item, at: 0)
                if self?.isFilter == true, let filterText = self?.filterText {
                    self?.predicateCardSeriesDatas(filterText: filterText)
                }
            case .failure(let error):
                print("插入卡片失败: \(error.localizedDescription)")
            }
        }
    }

    func updateItem(_ item: ImCardModel) throws {
        guard let itemId = item.identifier else {
            throw NSError(domain: "ImCardListViewModel", code: 4, userInfo: [NSLocalizedDescriptionKey: "Item identifier is required for update"])
        }

        let tableName = ImDBTableType.card.description
        dbShare.updateToDB(table: tableName, on: ImCardModel.Properties.all, with: item, where: ImCardModel.Properties.identifier == itemId) { [weak self] (result) in
            switch result {
            case .success():
                if let index = self?.items.firstIndex(where: { $0.identifier == itemId }) {
                    self?.items[index] = item
                }
                if self?.isFilter == true, let filterText = self?.filterText {
                    self?.predicateCardSeriesDatas(filterText: filterText)
                }
            case .failure(let error):
                print("更新卡片失败: \(error.localizedDescription)")
            }
        }
    }

    func deleteItem(at index: Int) throws {
        guard index >= 0 && index < currentCards.count else {
            throw NSError(domain: "ImCardListViewModel", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid index: \(index)"])
        }

        let itemToDelete = currentCards[index]

        guard let itemId = itemToDelete.identifier else {
            throw NSError(domain: "ImCardListViewModel", code: 7, userInfo: [NSLocalizedDescriptionKey: "Item identifier is required for deletion"])
        }

        let tableName = ImDBTableType.card.description

        if isFilter {
            filterCards.remove(at: index)
            if let indexInMain = items.firstIndex(where: { $0.identifier == itemId }) {
                dbShare.deleteFromTable(table: tableName, where: ImCardModel.Properties.identifier == itemId) { [weak self] (result) in
                    switch result {
                    case .success():
                        self?.items.remove(at: indexInMain)
                    case .failure(let error):
                        print("删除卡片失败: \(error.localizedDescription)")
                    }
                }
            }
        } else {
            dbShare.deleteFromTable(table: tableName, where: ImCardModel.Properties.identifier == itemId) { [weak self] (result) in
                switch result {
                case .success():
                    self?.items.remove(at: index)
                case .failure(let error):
                    print("删除卡片失败: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func fetchCards() {
        let tableName = ImDBTableType.card.description
        dbShare.queryFromDB(table: tableName, cls: ImCardModel.self) { [weak self] (result) in
            switch result {
            case .success(let fetchedItems):
                self?.items = fetchedItems
            case .failure(let error):
                print("加载卡片失败: \(error.localizedDescription)")
            }
        }
    }

    /// 创建新卡片
    func createNewCard(question: String, answer: String) -> ImCardModel {
        var newCard = ImCardModel()
        newCard.question = question
        newCard.answer = answer
        newCard.createTime = Date()
        newCard.state = CardState.new.rawValue
        newCard.dueDate = Date()
        newCard.difficulty = 0.0
        newCard.stability = 0.0
        newCard.reviewCount = 0
        newCard.lapseCount = 0
        newCard.relearningStep = 0
        newCard.cardType = CardType.standard.rawValue
        return newCard
    }

    func updateStatusInFilter() {
        filterText = nil
        isFilter = false
        filterCards = []
    }

    func predicateCardSeriesDatas(filterText: String?) {
        guard let filterText = filterText, !filterText.isEmpty else {
            updateStatusInFilter()
            return
        }
        self.filterText = filterText
        isFilter = true
        filterCards = items.filter {
            ($0.question?.contains(filterText) ?? false) ||
            ($0.answer?.contains(filterText) ?? false)
        }
    }
}

