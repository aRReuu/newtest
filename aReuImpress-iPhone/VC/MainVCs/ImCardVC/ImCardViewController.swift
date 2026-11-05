//
//  ImCardViewController.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 11/1/24.
//
//  卡片记忆视图控制器 - 主要的卡片学习界面
//  功能：展示卡片栈、处理滑动交互、管理复习逻辑
//  特色：支持壁纸显示、多种卡片类型；不集成原生 AI 对话
//
//  20241101 只做复习和巩固，本页面模块为简单的卡片记忆，后续优化
//  202503 实现历史回答分析
//  20250502 重构架构

import UIKit
import Combine

/// 卡片记忆视图控制器
/// 负责管理卡片的学习、复习和交互逻辑
/// 遵循苹果HIG设计规范，支持暗黑模式和无障碍访问
class ImCardViewController: ImBaseViewController, CAAnimationDelegate
{
    override var shouldShowFloatingButton: Bool {
        return true
    }

    private var cancellables = Set<AnyCancellable>()

    private let btnsView = UIView()
    private let cardView = UIView()

    /// 主视图模型
    private let viewModel: ImCardProtocol
    /// 卡片栈
    private let cardStack = SwipeCardStack()
    
    
    
    

    // MARK: - Initializers
    init() {
        self.viewModel = ImCardViewModel()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("This view controller should not be initialized from a storyboard.")
    }

    deinit {
    }
    
    override func viewWillDisappear(_ animated: Bool)
    {
        super.viewDidDisappear(animated)
        ImMusicPlayer.shared.stopPlaying()
    }

    override func viewDidLoad()
    {
        super.viewDidLoad()
        setupViews()
        initUISetting()
        setupBindings()
        // Native chat and automatic AI requests are retired.
        viewModel.fetchStudyCardQueue()
        ImMusicPlayer.shared.startPlaying()
    }
    
    private func setupViews() {
        view.backgroundColor = bgColor
        view.addSubview(cardView)
        view.addSubview(btnsView)

        cardView.translatesAutoresizingMaskIntoConstraints = false
        btnsView.translatesAutoresizingMaskIntoConstraints = false

        let cardViewConstant = defaultSpacing
        // 优化布局约束，按照HIG规范调整间距

        // cardView约束 - 添加最小尺寸保障
        let cardViewWidthConstraint = cardView.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -cardViewConstant * 2)
        let cardViewHeightConstraint = cardView.bottomAnchor.constraint(equalTo: btnsView.topAnchor, constant: -cardViewConstant)
        let cardViewMinWidthConstraint = cardView.widthAnchor.constraint(greaterThanOrEqualToConstant: 320)
        let cardViewMinHeightConstraint = cardView.heightAnchor.constraint(greaterThanOrEqualToConstant: 450)

        // 设置约束优先级，确保最小尺寸约束在必要时可以被打破
        cardViewMinWidthConstraint.priority = UILayoutPriority(999)
        cardViewMinHeightConstraint.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            // 卡片区域：占上部大部分空间，留出底部按钮区域
            cardView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: cardViewConstant),
            cardView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: cardViewConstant),
            cardView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -cardViewConstant),
            cardViewWidthConstraint,
            cardViewHeightConstraint,
            cardViewMinWidthConstraint,
            cardViewMinHeightConstraint,

            // 按钮区域：固定在底部，与卡片分离，增加底部安全区域
            btnsView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor,constant: cardViewConstant * 2),
            btnsView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor,constant: -cardViewConstant * 2),
            btnsView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -cardViewConstant),
            btnsView.heightAnchor.constraint(equalToConstant: defaultSpacing * 5)
        ])
    }


    
    private func initUISetting()
    {
        navigationItem.largeTitleDisplayMode = .never
        initCardSetting()
        initActionButtons()
        initMoreItemConfigure()
        // 模态跳转时添加关闭窗口
        if isPresented(){ 
            initNaviBar()
        }else{
            initLeftAddItemConfigure()
        }
    }
}

extension ImCardViewController
{
    func isPresented() -> Bool
    {
        return (self.presentingViewController != nil)
    }
    
    /// 初始化导航栏样式，优化视觉效果和用户体验
    private func initNaviBar()
    {
        self.isModalInPresentation = true
        let leftItem = UIBarButtonItem.init(barButtonSystemItem: .close,
                                            target: self,
                                            action: #selector(exitVC))
        leftItem.tintColor = ImpressV3Appearance.navigationActionInk
        leftItem.accessibilityLabel = "关闭卡片复习"
        navigationItem.leftBarButtonItem = leftItem
    }
}



// MARK: - 导航栏操作逻辑业务
extension ImCardViewController
{
    private func initLeftAddItemConfigure()
    {
        let addItem = UIBarButtonItem(image: UIImage(systemName: "plus.circle.fill"),
                                         style: .plain,
                                         target: self,
                                         action: nil)
        let cardAction = UIMenu(title: "生成卡片",
                                  options: .displayInline,
                                  children: [
                                    UIAction(title: imOneInsert, image: UIImage(systemName: "plus.square")) { [weak self] _ in
                                        self?.presentSubmitController()
                                    },
                                    UIAction(title: imBatchInsertDes, image: UIImage(systemName: "square.stack")) { [weak self] _ in
                                        self?.viewModel.batchInsertCards()
                                    }
                                  ])
        addItem.menu = UIMenu(title: "", children: [cardAction])
        navigationItem.leftBarButtonItem = addItem
    }
    
    private func initMoreItemConfigure()
    {
        let assistItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle.fill"),
                                         style: .plain,
                                         target: self,
                                         action: nil)
        assistItem.menu = initMoreMenuActions()
        navigationItem.rightBarButtonItems = [assistItem]
    }

    @objc private func refreshData() {
        viewModel.fetchStudyCardQueue()

        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }
    
    /// 更多按钮逻辑事件
    private func initMoreMenuActions() -> UIMenu
    {
        let refresh = UIAction(title: "刷新卡片", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
            self?.refreshData()
        }
        
        let del = UIAction(title: impressCellDelDes,
                           image: UIImage(systemName: "trash.fill"),
                           attributes: .destructive) { [weak self] _ in
            self?.deleteQuestionAction()
        }

        let cardList = UIAction(title: "卡片列表", image: UIImage(systemName: "list.bullet.rectangle")) { [weak self] _ in
            self?.showCardList()
        }

        let more = UIMenu(title: "",
                          options: .displayInline,
                          children: [
                            refresh,
                            cardList,
                            UIAction(title: "取词翻译(欧路词典)", image: UIImage(systemName: "character.book.closed")) {[weak self] _ in
                                self?.openEudic()
                            }
        ])
        //
        #if DEBUG
        let pilot = UIAction(title: "体验 V3 闪卡（测试）",
                             image: UIImage(systemName: "checkmark.shield")) { [weak self] _ in
            ImpressV3ReviewEnvironment.pilotEnabled = true
            ImpressV3NotificationCoordinator.shared.installDelegate()
            self?.navigationController?.pushViewController(
                ImpressV3ReviewViewController(), animated: true
            )
        }
        return UIMenu(title: "", children: [more, pilot, del])
        #else
        return UIMenu(title: "", children: [more, del])
        #endif
    }

    /// 显示卡片列表
    private func showCardList()
    {
        let cardListVC = ImCardListViewController()
        navigationController?.pushViewController(cardListVC, animated: true)
    }
    
    /// 打开欧路跨软件实时取词功能
    private func openEudic()
    {
        openApp(appName: "eudic://cross-app-translate")
    }


    
    /// 播放问题音频
    private func playFillWave()
    {
        guard let contentView = cardStack.topCard?.content as? ImMemoryCardView else{return}
        let questionText = contentView.questionTextView.text ?? ""
        ImTTSManager.shared.speak(text: questionText)
    }

    /// 修改当前卡片
    private func editCurrentCard()
    {
        guard let card = viewModel.getCurrentCard() else {
            ImAlertController.warningAlert("当前卡片无效")
            return
        }
        let submitVC = ImSubmitViewController(submitModel: card)
        submitVC.isEditMode = true
        submitVC.submitActionResult = { [weak self] (submitCard) in
            self?.viewModel.updateQA(in: submitCard)
        }
        present(submitVC, animated: true, completion: nil)
    }
    
    private func deleteQuestionAction()
    {
        ImAlertController.alert(message: deleteReviewMissionWarning,
                                buttons: alertDescription) {[weak self] (result) in
            if case .ok = result {
                self?.viewModel.deleteCurrentCard()
            }
        }
    }
    
    /// 新卡片插入
    private func presentSubmitController()
    {
        let submitVC = ImSubmitViewController.init(submitModel: ImCardModel())
        submitVC.submitActionResult = {[weak self] (card) in
            self?.viewModel.insertCard(by: card)
        }
        present(submitVC, animated: true, completion: nil)
    }
}

// MARK: - 底部卡片操作按钮业务逻辑
extension ImCardViewController
{
    private func createActionButton(imageName: String, color: UIColor, size: CGSize, isOval: Bool = false, tag: Int) -> UIButton {
        let button = UIButton(type: .custom)

        let symbolConfig = UIImage.SymbolConfiguration(pointSize: size.height * 0.45, weight: .medium)
        let normalImage = UIImage(systemName: imageName, withConfiguration: symbolConfig)
        button.setImage(normalImage, for: .normal)
        // 图标颜色使用原来的颜色但降低透明度，使其更柔和
        button.tintColor = color.withAlphaComponent(buttonIconAlpha)
        button.tag = tag
        button.translatesAutoresizingMaskIntoConstraints = false

        // 如果 isOval 为 true，则使用椭圆形按钮的样式
        if isOval {
            button.layer.cornerRadius = size.height / 2
        } else {
            button.layer.cornerRadius = size.height / 2
        }
        
        button.backgroundColor = secondaryBgColor

        button.addTarget(self, action: #selector(handleButtonAnimation(_:)), for: .touchDown)
        button.addTarget(self, action: #selector(handleButtonAnimation(_:)), for: .touchDragEnter)
        button.addTarget(self, action: #selector(handleButtonRelease(_:)), for: .touchUpInside)
        button.addTarget(self, action: #selector(handleButtonAnimation(_:)), for: .touchDragExit)
        button.addTarget(self, action: #selector(handleButtonAnimation(_:)), for: .touchCancel)

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: size.width),
            button.heightAnchor.constraint(equalToConstant: size.height)
        ])

        return button
    }
    
    private func initActionButtons()
    {
        let btnWidth: CGFloat = defaultSpacing * 3
        let notesButton = createActionButton(imageName: "doc.text",
                                             color: SwipeDirection.up.toLevelColor,
                                             size: CGSize(width: btnWidth * 2,
                                                          height: btnWidth),
                                             isOval: true,
                                             tag: 2)
        let webButton = createActionButton(imageName: "globe", color: SwipeDirection.right.toLevelColor, size: CGSize(width: btnWidth * 2.0, height: btnWidth), isOval: true, tag: 3)
        let editButton = createActionButton(imageName: "pencil", color: SwipeDirection.left.toLevelColor, size: CGSize(width: btnWidth * 2.0, height: btnWidth), tag: 0)


        // 不再使用UIStackView，改为手动布局以实现与卡片边距对齐
        btnsView.addSubview(editButton)
        btnsView.addSubview(webButton)
        btnsView.addSubview(notesButton)

        // 布局约束：最左边和最右边按钮与卡片边距对齐
        NSLayoutConstraint.activate([
            // 编辑按钮（最左边）与卡片左边距对齐
            editButton.leadingAnchor.constraint(equalTo: btnsView.leadingAnchor),
            editButton.centerYAnchor.constraint(equalTo: btnsView.centerYAnchor),

            // 笔记按钮（最右边）与卡片右边距对齐
            notesButton.trailingAnchor.constraint(equalTo: btnsView.trailingAnchor),
            notesButton.centerYAnchor.constraint(equalTo: btnsView.centerYAnchor),

            // Web按钮居中
            webButton.centerXAnchor.constraint(equalTo: btnsView.centerXAnchor),
            webButton.centerYAnchor.constraint(equalTo: btnsView.centerYAnchor)
        ])
    }

    @objc private func handleButtonAnimation(_ sender: UIButton) {
        UIView.animate(withDuration: 0.1) {
            sender.transform = sender.isTouchInside ? CGAffineTransform(scaleX: 0.9, y: 0.9) : .identity
        }
    }

    @objc private func handleButtonRelease(_ sender: UIButton) {
        UIView.animate(withDuration: 0.1, animations: {
            sender.transform = .identity
        }) { _ in
            self.handleClickAction(sender)
        }
    }
    
    private func handleClickAction(_ sender: UIButton)
    {
        switch sender.tag {
        case 0: // 编辑
            editCurrentCard()
        case 1: // 播放
//            playFillWave()
        break
        case 2: // 笔记列表
            showNotesList()
        case 3: // Web视图
            showWebView()
        default:
            break
        }
    }

    /// 显示Web视图
    private func showWebView() {
        let webVC = ImWebViewController.shared
        let navVC = ImNavigationViewController(rootViewController: webVC)
        navVC.modalPresentationStyle = .fullScreen
        present(navVC, animated: true, completion: nil)
    }
}


// MARK: - SwipeCardStackDelegate卡片逻辑业务
extension ImCardViewController: SwipeCardStackDataSource, SwipeCardStackDelegate
{
    func cardDidContinueSwipe(_ card: SwipeCard) {}

    func initCardSetting()
    {
        cardStack.delegate = self
        cardStack.dataSource = self
        cardStack.numberOfVisibleCards = 3
        cardView.addSubview(cardStack)
        cardStack.anchor(top: cardView.safeAreaLayoutGuide.topAnchor,
                         left: cardView.safeAreaLayoutGuide.leftAnchor,
                         bottom: cardView.safeAreaLayoutGuide.bottomAnchor,
                         right: cardView.safeAreaLayoutGuide.rightAnchor)
    }
    
    func cardStack(_ cardStack: SwipeCardStack,
                   cardForIndexAt index: Int) -> SwipeCard
    {
        let card = SwipeCard()
        card.swipeDirections = [.left, .up, .right, .down]
        for direction in card.swipeDirections {
            card.setOverlay(ImMemoryCardOverlay(direction: direction),
                            forDirection: direction)
        }

        guard let model = viewModel.getCardToSwipeCardStack(at: index) else {
            return card // Return empty card if no model
        }

        let cardType = CardType(rawValue: model.cardType ?? 0) ?? .standard

        self.btnsView.isHidden = false

        switch cardType {
        case .multipleChoice:
            let mcView = ImMultipleChoiceCardView(model: model)
            card.content = mcView
        case .standard, .image:
            let cardContent = ImMemoryCardView(model: model)
            card.content = cardContent

            if cardType == .image, let cardContent = card.content as? ImMemoryCardView {
                cardContent.onImageTapped = { [weak self] in
                    guard let self = self,
                          let imageData = model.imageData,
                          let image = UIImage(data: imageData) else {
                        return
                    }
                    let previewVC = ImImagePreviewViewController(image: image)
                    self.present(previewVC, animated: true, completion: nil)
                }
            }
        }
        // 统一设置卡片边框样式
        if let cardContent = card.content {
            cardContent.backgroundColor = secondaryBgColor
            cardContent.setCorner(cellCorner, borderWidth: 0, borderColor: secondaryBgColor)
        }
        return card
    }

    func numberOfCards(in cardStack: SwipeCardStack) -> Int
    {
        return viewModel.cardCount
    }

    func didSwipeAllCards(_ cardStack: SwipeCardStack)
    {
    }

    func cardStack(_ cardStack: SwipeCardStack,
                   didSwipeCardAt index: Int,
                   with direction: SwipeDirection)
    {
        viewModel.updateCard(in: direction)
    }

    
    @objc private func showMultipleChoiceAnswer(_ sender: UITapGestureRecognizer) {
        if let card = sender.view as? SwipeCard,
           let mcView = card.content as? ImMultipleChoiceCardView {
            mcView.showAnswer()
        }
    }

    /// The retired Chat tab must not be reopened. Use the existing read-only
    /// notes screen; external Web Chat remains a separate, explicit action.
    private func showNotesList() {
        navigationController?.pushViewController(
            ImpressNoteListTableViewController(), animated: true)
    }

    /// 显示随机笔记
    private func showRandomNote()
    {
        let notesViewModel = ImpressNotesViewModel()

        // 获取笔记数据
        notesViewModel.fetchNotes(by: self)

        // 延迟一下等待数据加载完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }

            if let randomNote = notesViewModel.getRandomNote() {
                let randomNoteVC = ImMarkdownViewController.init(note: randomNote)
                self.navigationController?.pushViewController(randomNoteVC, animated: true)
            } else {
                // 没有笔记时直接退出
                ImAlertController.alert(message: "恭喜完成复习！\n暂时没有笔记可以复习。")
                self.exitVC()
            }
        }
    }
}

// MARK: - 数据状态更新绑定处理业务
extension ImCardViewController
{
    private func setupBindings()
    {
        viewModel.studyCardQueuePublisher
            .combineLatest(viewModel.currentCardIndexPublisher)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.cardStack.reloadData()
            }
            .store(in: &cancellables)

        // 订阅一次性的动作事件
        viewModel.actionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .protocolSpecific(.card(let cardResult)):
                    switch cardResult {
                    case .cardDeleted(let index):
                        self.cardStack.deleteCards(atIndices: [index])
                    case .exit:
//                        self.exitVC()
                        // 显示随机笔记
                        self.showRandomNote()
                    default:
                        break
                    }
                case .isLoading(let isLoading):
                    isLoading ? loadShare.show() : loadShare.hide()
                case .success(let tip):
                    ImAlertController.alert(message: tip)
                case .errorOccurred(let error):
                    ImAlertController.warningAlert(error.localizedDescription)
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }
    




    /// fix
    @objc private func exitVC()
    {
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + ImAnimationConfig.cellMiddleDuration) { [weak self] in
            self?.navigationController?.popViewController(animated: true)
            self?.dismiss(animated: true)
        }
    }
}
