//
//  ImCardListViewController.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 11/1/24.
//

import UIKit
import Combine

///
/// 卡片列表控制器
class ImCardListViewController: ImBaseViewController {
    private var cancellables = Set<AnyCancellable>()

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let reuseID = ImCardListCell.reuseIdentifier
    private let refreshControl = UIRefreshControl()

    // MARK: - Properties
    private var viewModel: ImCardListViewModelProtocol!

    // MARK: - Initialization
    init() {
        self.viewModel = ImCardListViewModel()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupTableView()
        setupBindings()
        loadData()
    }
    
    // MARK: - Setup
    private func setupUI() {
        title = "卡片列表"
        navigationItem.largeTitleDisplayMode = .always
        searchControllerSetting()
        view.backgroundColor = bgColor

        let addButton = UIBarButtonItem(
            image: UIImage(systemName: "plus.circle.fill"),
            style: .plain,
            target: self,
            action: #selector(addNewCard)
        )
        addButton.accessibilityLabel = "添加新卡片"
        navigationItem.rightBarButtonItem = addButton
    }
    
    private func setupTableView() {
        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        tableView.backgroundColor = bgColor
        tableView.register(ImCardListCell.self, forCellReuseIdentifier: ImCardListCell.reuseIdentifier)
        tableView.delegate = self
        tableView.dataSource = self

        // Setup refresh control
        tableView.refreshControl = refreshControl
        refreshControl.addAction(UIAction { [weak self] _ in
            self?.loadData()
        }, for: .primaryActionTriggered)
    }
    
    private func setupBindings() {
        viewModel.itemsPublisher
            .combineLatest(viewModel.filterCardsPublisher, viewModel.isFilterPublisher)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                self?.refreshControl.endRefreshing()
                self?.tableView.reloadData()
            }
            .store(in: &cancellables)
    }

    private func loadData() {
        viewModel.fetchCards()
    }
    
    // MARK: - Actions
    @objc private func addNewCard() {
        let submitVC = ImSubmitViewController(submitModel: viewModel.createNewCard(question: "", answer: ""))
        submitVC.submitActionResult = { [weak self] (card: ImCardModel) in
            do {
                try self?.viewModel.insertItem(card)
            } catch {
                ImAlertController.warningAlert("创建卡片失败: \(error.localizedDescription)")
            }
        }
        present(submitVC, animated: true, completion: nil)
    }
    
    private func editCard(at indexPath: IndexPath) {
        guard let card = viewModel.getItem(at: indexPath.row) else { return }
        let submitVC = ImSubmitViewController(submitModel: card)
        submitVC.isEditMode = true
        submitVC.submitActionResult = { [weak self] (updatedCard: ImCardModel) in
            do {
                try self?.viewModel.updateItem(updatedCard)
            } catch {
                ImAlertController.warningAlert("更新卡片失败: \(error.localizedDescription)")
            }
        }
        present(submitVC, animated: true, completion: nil)
    }
    
    private func deleteCard(at indexPath: IndexPath) {
        ImAlertController.alert(message: deleteReviewMissionWarning, buttons: alertDescription) { [weak self] (result) in
            if case .ok = result {
                do {
                    try self?.viewModel.deleteItem(at: indexPath.row)
                } catch {
                    ImAlertController.warningAlert("删除卡片失败: \(error.localizedDescription)")
                }
            }
        }
    }

    private func searchControllerSetting() {
        let controller = UISearchController(searchResultsController: nil)
        controller.searchBar.placeholder = "问题/答案搜索..."
        controller.searchBar.delegate = self
        controller.searchBar.tintColor = titleColor
        controller.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = controller
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    private func searchDBByText(_ text: String? = nil) {
        guard let t = text, !t.isEmpty else {
            viewModel.updateStatusInFilter()
            return
        }
        viewModel.predicateCardSeriesDatas(filterText: t)
    }
}

// MARK: - UITableViewDelegate, UITableViewDataSource
extension ImCardListViewController: UITableViewDelegate, UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return viewModel.itemCount
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: ImCardListCell.reuseIdentifier, for: indexPath) as? ImCardListCell,
              let card = viewModel.getItem(at: indexPath.row) else {
            return UITableViewCell()
        }
        cell.configure(with: card)
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        editCard(at: indexPath)
    }
    
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            deleteCard(at: indexPath)
        }
    }

    func tableView(_ tableView: UITableView, titleForDeleteConfirmationButtonForRowAt indexPath: IndexPath) -> String? {
        return impressCellDelDes
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { suggestedActions in
            let editAction = UIAction(title: "编辑", image: UIImage(systemName: "pencil")) { [weak self] action in
                self?.editCard(at: indexPath)
            }
            let deleteAction = UIAction(title: "删除", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] action in
                self?.deleteCard(at: indexPath)
            }
            return UIMenu(title: "", children: [editAction, deleteAction])
        }
    }
}

// MARK: - UISearchBarDelegate
extension ImCardListViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        searchDBByText(searchText)
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchDBByText()
    }
}
