//
//  ImMarkdownViewController.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 9/19/25.
//

import UIKit
import ImageIO
import WebKit
import SwiftUI
import Translation
import ImpressReviewCore
import MarkdownView

class ImMarkdownViewController: ImBaseViewController
{
    private let textView = ImExtractTextView.init(frame: .zero)
    private let searchController = UISearchController(searchResultsController: nil)
    private var note: ImNoteModel?
    private var originalText: String = ""
    private var originalAttributedText: NSAttributedString? // 保存初始的富文本
    private var lastSearchText: String = ""
    private var searchWorkItem: DispatchWorkItem? // 搜索任务
    private var searchRanges: [NSRange] = [] // 存储所有匹配项的范围
    private var currentSearchIndex: Int = -1 // 当前高亮的匹配项索引

    // 搜索导航按钮
    private var previousItem: UIBarButtonItem!
    private var nextItem: UIBarButtonItem!

    // 生成卡片浮动按钮
    private let generateCardButton = UIButton(type: .custom)
    private var isDragging = false
    private var initialCenter: CGPoint = .zero

    convenience init(note:ImNoteModel? = nil)
    {
        self.init()
        self.note = note
    }
    
    override func viewDidLoad()
    {
        super.viewDidLoad()
        setupUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setupFloatingButtons()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        hideFloatingButtons()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // 屏幕旋转时重新定位按钮
        if generateCardButton.superview != nil {
            let buttonSize = defaultSpacing * 3
            let spacing = defaultSpacing
            // 确保按钮在新的安全区域内
            var newY = view.safeAreaLayoutGuide.layoutFrame.maxY - buttonSize - spacing
            if newY < view.safeAreaInsets.top + buttonSize {
                newY = view.safeAreaInsets.top + spacing + buttonSize
            }

            generateCardButton.frame.origin.y = newY

            // 确保水平位置也在安全区域内
            var newX = generateCardButton.frame.origin.x
            let minX = view.safeAreaInsets.left + spacing
            let maxX = view.bounds.width - view.safeAreaInsets.right - buttonSize - spacing

            if newX < minX {
                newX = minX
            } else if newX > maxX {
                newX = maxX
            }

            generateCardButton.frame.origin.x = newX
        }
    }

    private func setupUI()
    {
        view.backgroundColor = bgColor
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.title = note?.mainTitle

        // --- Performance Optimizations ---
        textView.isOpaque = true // Reduce GPU blending
        textView.dataDetectorTypes = [] // Disable data detectors to prevent overhead
        if #available(iOS 12.0, *) {
            textView.layoutManager.allowsNonContiguousLayout = true // Enable background layout processing
        }
        // --- End of Optimizations ---

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.alwaysBounceVertical = true
        textView.backgroundColor = bgColor
        textView.textColor = titleColor
        textView.isEditable = false // 不允许编辑内容
        let text = note?.markdownText ?? ""
        // 使用Down库渲染markdown文本
        textView.setMarkdownText(text)
        originalText = text
        // 记录初始 attributed 文本（使用Down渲染后的富文本）
        originalAttributedText = textView.attributedText

        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
        ])
        //
//        initMoreItemConfigure()
        searchControllerSetting()
        setupSearch()
    }

    private func setupFloatingButtons()
    {
        generateCardButton.setImage(UIImage(systemName: "plus.circle.fill"),
                                    for: .normal)
        generateCardButton.tintColor = .white
        generateCardButton.backgroundColor = funBtnColor
        generateCardButton.addTarget(self,
                                     action: #selector(generateCardFromNote),
                                     for: .touchUpInside)
        view.addSubview(generateCardButton)

        // 设置初始位置（左下角）
        let buttonSize = defaultSpacing * 4
        let spacing = defaultSpacing
        generateCardButton.frame = CGRect(
            x: spacing,
            y: view.safeAreaLayoutGuide.layoutFrame.maxY - buttonSize,
            width: buttonSize,
            height: buttonSize
        )
        generateCardButton.setDefaultCorner()
        // 添加拖拽手势
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        generateCardButton.addGestureRecognizer(panGesture)
    }

    private func hideFloatingButtons() {
        generateCardButton.removeFromSuperview()
    }

    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)

        switch gesture.state {
        case .began:
            isDragging = false
            initialCenter = generateCardButton.center
        case .changed:
            // 移动按钮
            let newCenter = CGPoint(
                x: initialCenter.x + translation.x,
                y: initialCenter.y + translation.y
            )

            // 限制在安全区域内
            let safeAreaInsets = view.safeAreaInsets
            let buttonRadius: CGFloat = defaultSpacing * 1.5
            let minX = safeAreaInsets.left + buttonRadius
            let maxX = view.bounds.width - safeAreaInsets.right - buttonRadius
            let minY = safeAreaInsets.top + buttonRadius
            let maxY = view.bounds.height - safeAreaInsets.bottom - buttonRadius

            let clampedX = min(max(newCenter.x, minX), maxX)
            let clampedY = min(max(newCenter.y, minY), maxY)

            generateCardButton.center = CGPoint(x: clampedX, y: clampedY)
            isDragging = true
        case .ended:
            if !isDragging {
                // 如果没有拖拽，则执行点击事件
                generateCardFromNote()
            } else {
                // 自动吸附到屏幕边缘
                let screenWidth = view.bounds.width
                let centerX = generateCardButton.center.x

                UIView.animate(withDuration: 0.3) {
                    let targetX = centerX < screenWidth / 2 ?
                        defaultSpacing + defaultSpacing * 1.5 : // 左边
                        screenWidth - defaultSpacing - defaultSpacing * 1.5 // 右边

                    self.generateCardButton.center.x = targetX
                }
            }
        default:
            break
        }
    }

    private func setupSearch()
    {
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "搜索文件内容..."
        searchController.searchBar.delegate = self
        definesPresentationContext = true

        // 创建键盘上方工具栏
        let accessoryView = createSearchAccessoryView()
        searchController.searchBar.inputAccessoryView = accessoryView
    }
    
    private func clearSearchHighlight()
    {
        // 恢复“原始富文本”，而不是用统一样式重建
        if let original = originalAttributedText {
            textView.attributedText = original
        } else {
            textView.text = originalText
        }
        // 重置搜索状态
        searchRanges.removeAll()
        currentSearchIndex = -1
        // 更新按钮状态
        updateSearchButtonsState()
        // 不强制滚回顶部，避免滚动位置突兀变化
        // textView.setContentOffset(.zero, animated: true)
    }

    /// 更新搜索导航按钮状态
    private func updateSearchButtonsState()
    {
        let hasMatches = !searchRanges.isEmpty
        previousItem?.isEnabled = hasMatches
        nextItem?.isEnabled = hasMatches

        // 如果只有一个匹配项，禁用上一个按钮（因为循环时上一个就是自己）
        if searchRanges.count == 1 {
            previousItem?.isEnabled = false
        }

        // 更新搜索结果计数显示
        updateSearchResultCount()
    }

    /// 更新搜索结果计数显示
    private func updateSearchResultCount()
    {
        if searchRanges.isEmpty {
            searchController.searchBar.placeholder = "搜索文件内容..."
        } else {
            let count = searchRanges.count
            let current = currentSearchIndex + 1 // 转换为1-based索引
            // 使用更明显的方式显示搜索结果计数
            searchController.searchBar.placeholder = "搜索结果: \(current)/\(count)"
            // 如果搜索栏有文本，我们可以在文本中显示计数
            if let searchText = searchController.searchBar.text, !searchText.isEmpty {
                searchController.searchBar.text = "\(searchText) (\(current)/\(count))"
            }
        }
    }
}


extension ImMarkdownViewController
{
    private func initMoreItemConfigure()
    {
        let assistItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"),
                                         style: .plain,
                                         target: self,
                                         action: nil)
        assistItem.tintColor = ImpressV3Appearance.navigationActionInk
        assistItem.menu = initMoreMenuActions()
        navigationItem.rightBarButtonItems = [assistItem]
    }
    
    /// 更多按钮逻辑事件
    private func initMoreMenuActions() -> UIMenu
    {
        let saveAction = UIAction(title: "保存(同步Obsidian)") { [weak self] _ in
            self?.saveButtonTapped()
        }
        return UIMenu(title: "", children: [saveAction])
    }
    
    @objc private func generateCardFromNote() {
        let content = textView.text ?? ""
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ImAlertController.warningAlert("笔记内容为空，无法生成卡片。")
            return
        }

        // 从笔记内容提取问题和答案
        // 使用第一行作为问题，其余作为答案
        let lines = content.components(separatedBy: .newlines)
        let question = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "笔记卡片"
//        let answer = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // 创建卡片模型
        var cardModel = ImCardModel()
        cardModel.question = question
//        cardModel.answer = answer.isEmpty ? content : answer // 如果没有多行内容，整个内容作为答案
        cardModel.cardType = CardType.standard.rawValue
        cardModel.createTime = Date()

        // FSRS initial state
        cardModel.state = CardState.new.rawValue
        cardModel.dueDate = Date()
        cardModel.difficulty = 0.0
        cardModel.stability = 0.0
        cardModel.reviewCount = 0
        cardModel.lapseCount = 0
        cardModel.relearningStep = 0

        // 弹出编辑界面让用户确认或修改
        let submitVC = ImSubmitViewController(submitModel: cardModel)
        submitVC.submitActionResult = { (updatedCard: ImCardModel) in

            let cardTable = ImDBTableType.card.description
            dbShare.insertToDB(intoTable: cardTable, with: [updatedCard]) { result in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    switch result {
                    case .success():
//                        ImAlertController.alert(message: "复习卡片创建成功！")
                        break
                    case .failure(let error):
                        ImAlertController.warningAlert("创建卡片失败：\(error.localizedDescription)")
                    }
                }
            }
        }
        present(submitVC, animated: true, completion: nil)
    }

    @objc private func saveButtonTapped()
    {
        // P0-0: never serialize the rendered UITextView back to source Markdown.
        // Rich text is not a lossless Obsidian AST. The original vault stays
        // read-only until the guarded P0-3 write coordinator is accepted.
        ImAlertController.warningAlert(
            "Obsidian 源文件目前为只读。请使用独立认知记录；双向写回必须经过版本比对和确认。")
    }




}



// MARK: - UISearchBarDelegate

extension ImMarkdownViewController: UISearchBarDelegate
{
    private func searchControllerSetting()
    {
        let controller = UISearchController.init(searchResultsController: nil)
        controller.searchBar.placeholder = impressPageForNotesSearchBarDes
        controller.searchBar.delegate = self
        controller.searchBar.tintColor = titleColor
        controller.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = controller
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    func searchBar(_ searchBar: UISearchBar,
                   textDidChange searchText: String)
    {
        lastSearchText = searchText
        guard !searchText.isEmpty else {
        clearSearchHighlight()
            return
    }
        highlightAndScroll(to: searchText)
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar)
    {
        clearSearchHighlight()
        searchBar.text = nil
        searchBar.resignFirstResponder()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar)
    {
        searchBar.resignFirstResponder()
        if let text = searchBar.text, !text.isEmpty {
            highlightAndScroll(to: text)
        }
    }



    /// 滚动到上一个搜索匹配项
    @objc private func scrollToPreviousMatch()
    {
        guard !searchRanges.isEmpty else { return }

        // 更新当前索引，循环处理
        currentSearchIndex = (currentSearchIndex - 1 + searchRanges.count) % searchRanges.count
        let range = searchRanges[currentSearchIndex]

        // 滚动到可见位置
        textView.scrollRangeToVisible(range)

        // 设置光标位置并添加临时高亮效果
        textView.selectedRange = NSRange(location: range.location, length: 0)

        // 添加临时高亮效果以突出显示当前匹配项
        highlightCurrentMatch(range)
    }

    /// 滚动到下一个搜索匹配项
    @objc private func scrollToNextMatch()
    {
        guard !searchRanges.isEmpty else { return }

        // 更新当前索引，循环处理
        currentSearchIndex = (currentSearchIndex + 1) % searchRanges.count
        let range = searchRanges[currentSearchIndex]

        // 滚动到可见位置
        textView.scrollRangeToVisible(range)

        // 设置光标位置并添加临时高亮效果
        textView.selectedRange = NSRange(location: range.location, length: 0)

        // 添加临时高亮效果以突出显示当前匹配项
        highlightCurrentMatch(range)
    }

    /// 高亮显示当前匹配项
    private func highlightCurrentMatch(_ range: NSRange)
    {
        // 创建当前文本的可变副本
        let mutableText = NSMutableAttributedString(attributedString: textView.attributedText)

        // 先清除所有匹配项的高亮
        for searchRange in searchRanges {
            mutableText.removeAttribute(.backgroundColor, range: searchRange)
        }

        // 重新应用所有匹配项的高亮
        for searchRange in searchRanges {
            mutableText.addAttribute(.backgroundColor,
                                   value: highlightColor.withAlphaComponent(highlightAlpha + 0.05),
                                   range: searchRange)
        }

        // 对当前匹配项应用更明显的高亮
        mutableText.addAttribute(.backgroundColor,
                               value: highlightColor.withAlphaComponent(highlightAlpha + 0.2),
                               range: range)

        // 应用更新后的文本
        textView.attributedText = mutableText

        // 确保当前匹配项可见
        textView.scrollRangeToVisible(range)
    }



    /// 创建搜索键盘上方工具栏
    private func createSearchAccessoryView() -> UIToolbar
    {
        let toolbar = UIToolbar()
        toolbar.sizeToFit()

        // 创建上一个按钮
        previousItem = UIBarButtonItem(image: UIImage(systemName: "chevron.up.circle.fill"),
                                       style: .plain,
                                       target: self,
                                       action: #selector(scrollToPreviousMatch))
        previousItem.tintColor = ImpressV3Appearance.navigationActionInk

        // 创建下一个按钮
        nextItem = UIBarButtonItem(image: UIImage(systemName: "chevron.down.circle.fill"),
                                   style: .plain,
                                   target: self,
                                   action: #selector(scrollToNextMatch))
        nextItem.tintColor = ImpressV3Appearance.navigationActionInk

        // 创建弹性空间
        let flexibleSpace = UIBarButtonItem(barButtonSystemItem: .flexibleSpace,
                                            target: nil,
                                            action: nil)

        // 设置工具栏项目
        toolbar.items = [flexibleSpace, previousItem, nextItem, flexibleSpace]

        return toolbar
    }

    // 异步高亮文本并滚动到第一个匹配项，以避免阻塞UI线程
    private func highlightAndScroll(to keyword: String)
    {
        // 1. 取消之前的搜索任务，实现搜索防抖
        searchWorkItem?.cancel()

        // 2. 创建一个新的后台任务
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            // 使用原始文本进行计算
            let base = (self.originalAttributedText ?? NSAttributedString(string: self.originalText))
            let mutable = NSMutableAttributedString(attributedString: base)
            let full = mutable.string as NSString

            var allRanges: [NSRange] = []
            var searchRange = NSRange(location: 0, length: full.length)

            // 检查任务在开始前是否已被取消
            guard !(self.searchWorkItem?.isCancelled ?? true) else { return }

            while searchRange.location < full.length {
                // 在循环的每次迭代中检查取消状态，以便尽快退出
                if self.searchWorkItem?.isCancelled ?? true { return }

                let found = full.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                if found.location == NSNotFound { break }

                mutable.addAttribute(.backgroundColor, value: highlightColor.withAlphaComponent(highlightAlpha + 0.05), range: found)
                allRanges.append(found)
                let next = found.location + found.length
                searchRange = NSRange(location: next, length: full.length - next)
            }

            // 在完成所有计算后，再次检查取消状态
            guard !(self.searchWorkItem?.isCancelled ?? true) else { return }

            // 3. 安全地切换回主线程来更新UI
            DispatchQueue.main.async {
                // 在更新UI之前做最后一次检查
                if !(self.searchWorkItem?.isCancelled ?? true) {
                    self.searchRanges = allRanges
                    self.currentSearchIndex = allRanges.isEmpty ? -1 : 0
                    self.textView.attributedText = mutable
                    if !allRanges.isEmpty {
                        let firstRange = allRanges[0]
                        self.textView.scrollRangeToVisible(firstRange)
                        // 将光标移动到找到的第一个匹配项的开头
                        self.textView.selectedRange = NSRange(location: firstRange.location, length: 0)
                        // 高亮显示第一个匹配项
                        self.highlightCurrentMatch(firstRange)
                    }
                    // 更新按钮状态
                    self.updateSearchButtonsState()
                }
            }
        }

        self.searchWorkItem = workItem

        // 4. 将任务分派到全局后台队列执行，以避免阻塞UI
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }
}


// MARK: - P0 external Vault source viewer (never edits rendered NSAttributedString)

/// The source-of-truth is always the original byte buffer in ImVaultRawDocument.
/// Rich text is a disposable READ-ONLY projection and is never serialized back
/// as Markdown; unknown Obsidian syntax remains intact in source mode.
@MainActor
final class ImVaultDocumentController: UIViewController {
    private var document: ImVaultRawDocument
    private let sourceSectionDigest: String?
    private var hasAppearedOnce = false
    private var latestReadSerial = 0
    private let readingView = UITextView()
    private let richView = ImpressMarkdownOfflineView()
    private let readerHeader = UIStackView()
    private var contentTopWithHeader: NSLayoutConstraint?
    private var contentTopWithoutHeader: NSLayoutConstraint?
    private let propertyPanel = UIStackView()
    private let propertyToggle = UIButton(type: .system)
    private let propertyScroll = UIScrollView()
    private let propertyRows = UIStackView()
    private var propertyScrollHeight: NSLayoutConstraint?
    private var propertiesExpanded = true
    private let canvasHost = UIView()
    private var canvasGraph: ImpressCanvasNativeView?
    private var drawingGraph: ImpressExcalidrawNativeView?
    private let documentTitleLabel = UILabel()
    private var classifiedDrawingDigest = ""
    private var isPluginDrawingMarkdown = false

    /// A .md path stays .md for Vault identity/Chat keys. Only its display
    /// projection changes after a valid, bounded Drawing-fence parse.
    private func drawingDisplayFormat() -> ImVaultDocumentFormat? {
        let format = document.identity.documentFormat
        if format == .excalidrawMarkdown || format == .excalidrawJSON {
            return format
        }
        guard format == .markdown else { return nil }
        if classifiedDrawingDigest != document.digest {
            classifiedDrawingDigest = document.digest
            isPluginDrawingMarkdown =
                ImpressObsidianDrawingEnvelope.isSupportedDrawing(document.sourceBytes)
        }
        return isPluginDrawingMarkdown ? .excalidrawMarkdown : nil
    }
    private var documentTitleText: String {
        URL(fileURLWithPath: document.identity.relativePath)
            .deletingPathExtension().lastPathComponent
    }
    private var preparedMarkdown: String?
    // Latest-request-wins for asynchronous, version-scoped embedded previews.
    private var previewGeneration: UInt64 = 0
    private var isSourceMode = false
    private let renderer = MarkdownKitRenderer()

    init(document: ImVaultRawDocument, sourceSectionDigest: String? = nil) {
        self.document = document
        self.sourceSectionDigest = sourceSectionDigest
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(document:) required") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        documentTitleLabel.text = documentTitleText
        if hasAppearedOnce {
            // Re-read after the draft editor, QA source write, other Files
            // provider edits, or a child discussion. Never keep showing a
            // stale cached note as though it were the authoritative original.
            withVerifiedLiveDocument()
        }
        hasAppearedOnce = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        // A child reader or dismissed page must not accept an older embed
        // projection after returning to a different source version.
        previewGeneration &+= 1
        super.viewWillDisappear(animated)
    }

    /// All actions that consume Markdown (AI questions, Chat context and new
    /// drafts) read the CURRENT scoped source. A read-only preview may be
    /// cached for scrolling, but it is not an authority for future edits.
    private func withVerifiedLiveDocument(
        _ action: ((ImVaultRawDocument) -> Void)? = nil
    ) {
        let identity = document.identity
        guard ImVaultReadOnlyProbe.shared.authorizedVaultID == identity.vaultID else {
            showVaultError(V3L("Vault 授权已失效"), error: ImVaultSyncFailure.wrongVault)
            return
        }
        latestReadSerial += 1
        let readSerial = latestReadSerial
        ImVaultReadSync.shared.read(identity) { [weak self] result in
            guard let self, self.latestReadSerial == readSerial else { return }
            switch result {
            case .failure(let error):
                self.navigationItem.prompt = V3L("源文件无法回读；本页可能是旧内容")
                if action != nil { self.showVaultError(V3L("来源笔记读取失败"), error: error) }
            case .success(let latest):
                guard latest.identity == identity else {
                    self.showVaultError(V3L("来源身份已失效"), error: ImVaultSyncFailure.wrongVault)
                    return
                }
                self.navigationItem.prompt = nil
                if latest.digest != self.document.digest {
                    self.document = latest
                    self.preparedMarkdown = nil
                    self.documentTitleLabel.text = self.documentTitleText
                    self.configureDocumentActions()
                    self.renderBody()
                    self.prepareLivePreview(for: latest)
                } else if latest.identity.documentFormat == .markdown &&
                          latest.markdown.contains("![[") {
                    // A referenced drawing/note may change even when the host
                    // Markdown's own SHA remains the same. Refresh only notes
                    // with actual Obsidian embeds after a child page returns.
                    self.prepareLivePreview(for: latest)
                }
                action?(latest)
            }
        }
    }

    private func prepareLivePreview(for current: ImVaultRawDocument) {
        previewGeneration &+= 1
        let generation = previewGeneration
        guard current.identity.documentFormat == .markdown,
              drawingDisplayFormat() == nil else { return }
        ImVaultReadSync.shared.prepareAuthorizedPreview(current) { [weak self] result in
            guard let self, self.previewGeneration == generation,
                  self.document.digest == current.digest,
                  self.document.identity == current.identity,
                  ImVaultReadOnlyProbe.shared.authorizedVaultID == current.identity.vaultID
                  else { return }
            if case let .success(safeMarkdown) = result {
                self.preparedMarkdown = safeMarkdown
                if !self.isSourceMode { self.renderBody() }
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "" // Full document name now leads the reader, not the navigation bar.
        view.backgroundColor = ImpressV3Appearance.page
        navigationItem.largeTitleDisplayMode = .never
        ImpressV3Appearance.styleReadingTextView(readingView)
        // The whole reading page is continuous, not a nested rounded card.
        richView.backgroundColor = ImpressV3Appearance.surface
        richView.layer.cornerRadius = 0
        richView.clipsToBounds = false
        readingView.textAlignment = .left
        documentTitleLabel.text = documentTitleText
        documentTitleLabel.font = ImpressV3Appearance.Typography.documentTitle
        documentTitleLabel.adjustsFontForContentSizeCategory = true
        documentTitleLabel.textColor = ImpressV3Appearance.primaryText
        documentTitleLabel.numberOfLines = 2
        documentTitleLabel.lineBreakMode = .byTruncatingTail
        // Keep the title bounded so drawing and Canvas content retain space.
        // Otherwise the native Canvas/Excalidraw viewport can be pushed
        // entirely below the visible screen and excluded from XCUITest AX tree.
        documentTitleLabel.setContentHuggingPriority(.required, for: .vertical)
        documentTitleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        readingView.setContentHuggingPriority(.defaultLow, for: .vertical)
        documentTitleLabel.accessibilityIdentifier = "impress.notes.document-title"
        documentTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        readerHeader.axis = .vertical
        readerHeader.alignment = .fill
        readerHeader.spacing = ImpressV3Appearance.Metrics.rowSpacing
        readerHeader.translatesAutoresizingMaskIntoConstraints = false
        readerHeader.addArrangedSubview(documentTitleLabel)
        propertyPanel.axis = .vertical
        propertyPanel.alignment = .fill
        propertyPanel.spacing = 4
        propertyPanel.isLayoutMarginsRelativeArrangement = true
        propertyPanel.layoutMargins = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        propertyPanel.backgroundColor = ImpressV3Appearance.surface
        propertyPanel.layer.cornerRadius = ImpressV3Appearance.Radius.field
        propertyPanel.isHidden = true
        propertyToggle.setTitleColor(ImpressV3Appearance.primaryText, for: .normal)
        propertyToggle.contentHorizontalAlignment = .leading
        propertyToggle.titleLabel?.font = ImpressV3Appearance.Typography.footnote
        propertyToggle.titleLabel?.adjustsFontForContentSizeCategory = true
        propertyToggle.accessibilityIdentifier = "impress.notes.properties-toggle"
        propertyToggle.addTarget(self, action: #selector(toggleProperties), for: .touchUpInside)
        propertyToggle.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        propertyPanel.addArrangedSubview(propertyToggle)
        propertyScroll.showsVerticalScrollIndicator = true
        propertyScroll.accessibilityIdentifier = "impress.notes.properties-scroll"
        propertyRows.axis = .vertical
        propertyRows.alignment = .fill
        propertyRows.spacing = 10
        propertyRows.translatesAutoresizingMaskIntoConstraints = false
        propertyScroll.addSubview(propertyRows)
        NSLayoutConstraint.activate([
            propertyRows.topAnchor.constraint(equalTo: propertyScroll.contentLayoutGuide.topAnchor),
            propertyRows.bottomAnchor.constraint(equalTo: propertyScroll.contentLayoutGuide.bottomAnchor),
            propertyRows.leadingAnchor.constraint(equalTo: propertyScroll.contentLayoutGuide.leadingAnchor),
            propertyRows.trailingAnchor.constraint(equalTo: propertyScroll.contentLayoutGuide.trailingAnchor),
            propertyRows.widthAnchor.constraint(equalTo: propertyScroll.frameLayoutGuide.widthAnchor)
        ])
        propertyScrollHeight = propertyScroll.heightAnchor.constraint(equalToConstant: 0)
        propertyScrollHeight?.isActive = true
        propertyPanel.addArrangedSubview(propertyScroll)
        readerHeader.addArrangedSubview(propertyPanel)
        readingView.translatesAutoresizingMaskIntoConstraints = false
        richView.translatesAutoresizingMaskIntoConstraints = false
        canvasHost.translatesAutoresizingMaskIntoConstraints = false
        canvasHost.isHidden = true
        canvasHost.isAccessibilityElement = false
        canvasHost.shouldGroupAccessibilityChildren = false
        canvasHost.accessibilityIdentifier = "impress.canvas.host"
        richView.isScrollEnabled = true
        // Do not load external Markdown images or navigate to arbitrary
        // web URLs without an explicit user request. Obsidian Vault is private.
        richView.onTouchLink = { [weak self] request in
            guard let url = request.url,
                  url.scheme == "https", url.host == "impress.invalid",
                  url.path == "/wiki",
                  let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                      .queryItems?.first(where: { $0.name == "target" })?.value else {
                // Never leave the app for an unapproved remote URL.
                return false
            }
            self?.followWikiLink(target)
            return false
        }
        view.addSubview(readerHeader)
        view.addSubview(readingView)
        view.addSubview(richView)
        view.addSubview(canvasHost)
        let safe = view.safeAreaLayoutGuide
        let inset = ImpressV3Appearance.Metrics.screenInset
        let top = ImpressV3Appearance.Metrics.compactInset
        let bottom = ImpressV3Appearance.Metrics.compactInset
        let gap = ImpressV3Appearance.Metrics.rowSpacing
        let withHeader = readingView.topAnchor.constraint(
            equalTo: readerHeader.bottomAnchor, constant: gap)
        let withoutHeader = readingView.topAnchor.constraint(
            equalTo: safe.topAnchor, constant: 0)
        contentTopWithHeader = withHeader
        contentTopWithoutHeader = withoutHeader
        withHeader.isActive = true
        NSLayoutConstraint.activate([
            readerHeader.topAnchor.constraint(equalTo: safe.topAnchor, constant: top),
            readerHeader.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: inset),
            readerHeader.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -inset),
            readingView.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -bottom),
            readingView.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: inset),
            readingView.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -inset),
            richView.topAnchor.constraint(equalTo: readingView.topAnchor),
            richView.bottomAnchor.constraint(equalTo: readingView.bottomAnchor),
            richView.leadingAnchor.constraint(equalTo: readingView.leadingAnchor),
            richView.trailingAnchor.constraint(equalTo: readingView.trailingAnchor),
            canvasHost.topAnchor.constraint(equalTo: readingView.topAnchor),
            canvasHost.bottomAnchor.constraint(equalTo: readingView.bottomAnchor),
            canvasHost.leadingAnchor.constraint(equalTo: readingView.leadingAnchor),
            canvasHost.trailingAnchor.constraint(equalTo: readingView.trailingAnchor)
        ])
        configureDocumentActions()
        renderBody()
        // Resolve only authorized, bounded previews; never update the Vault.
        prepareLivePreview(for: document)
    }

    private func configureDocumentActions() {
        let draft = UIBarButtonItem(
            image: UIImage(systemName: "square.and.pencil"), style: .plain,
            target: self, action: #selector(editDraft))
        draft.accessibilityLabel = V3L("编辑独立草稿")
        draft.accessibilityIdentifier = "impress.notes.draft"
        let source = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"), style: .plain,
            target: self, action: #selector(toggleSource))
        source.accessibilityLabel = V3L("切换 Markdown 源码")
        source.accessibilityIdentifier = "impress.notes.source-toggle"
        let generate = UIBarButtonItem(
            image: UIImage(systemName: "questionmark.square"), style: .plain,
            target: self, action: #selector(generateAIQuestions))
        generate.accessibilityLabel = V3L("根据笔记生成综合问题")
        generate.accessibilityIdentifier = "impress.notes.generate-questions"
        let links = UIBarButtonItem(image: UIImage(systemName: "rectangle.stack"),
            style: .plain, target: self, action: #selector(openLinkedCards))
        links.accessibilityLabel = V3L("关联卡片")
        links.accessibilityIdentifier = "impress.notes.linked-cards"
        let discussion = UIBarButtonItem(image: UIImage(systemName: "bubble.left.and.bubble.right"),
            style: .plain, target: self, action: #selector(openNativeNoteDiscussion))
        discussion.accessibilityLabel = V3L("AI 讨论")
        discussion.accessibilityIdentifier = "impress.notes.ai-discussion"
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"),
            style: .plain, target: nil, action: nil)
        more.accessibilityLabel = V3L("更多笔记操作")
        more.menu = UIMenu(children: [
            UIAction(title: V3L("编辑独立草稿"),
                image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in self?.editDraft() },
            UIAction(title: V3L("查看 Markdown 源码"),
                image: UIImage(systemName: "chevron.left.forwardslash.chevron.right")) {
                    [weak self] _ in self?.toggleSource()
                },
            UIAction(title: V3L("根据笔记生成卡片"),
                image: UIImage(systemName: "questionmark.square")) {
                    [weak self] _ in self?.generateAIQuestions()
                },
            UIAction(title: V3L("关联卡片"),
                image: UIImage(systemName: "rectangle.stack")) {
                    [weak self] _ in self?.openLinkedCards()
                },
            UIAction(title: V3L("核查笔记更新是否影响原卡"),
                image: UIImage(systemName: "checkmark.shield")) {
                    [weak self] _ in self?.checkLinkedCardChanges()
                }
        ])
        if document.identity.documentFormat != .markdown ||
           drawingDisplayFormat() != nil {
            // Readable complex files have no generic Markdown edit authority.
            var actions: [UIMenuElement] = [
                UIAction(title: V3L("查看原始文件内容"),
                    image: UIImage(systemName: "chevron.left.forwardslash.chevron.right")) {
                        [weak self] _ in self?.toggleSource()
                    }
            ]
            if document.identity.documentFormat == .jsonCanvas {
                actions.append(UIAction(title: V3L("所选画布节点预览并加入 Chat"),
                    image: UIImage(systemName: "square.stack")) {
                        [weak self] _ in self?.reviewSelectedCanvas()
                })
            } else if drawingDisplayFormat() != nil {
                actions.append(UIAction(title: V3L("所选绘图元素预览并加入 Chat"),
                    image: UIImage(systemName: "square.stack")) {
                        [weak self] _ in self?.reviewSelectedDrawing()
                })
                actions.append(UIAction(title: V3L("选择整张绘图"),
                    image: UIImage(systemName: "square.dashed.inset.filled")) {
                        [weak self] _ in self?.drawingGraph?.selectAllActive()
                })
                actions.append(UIAction(title: V3L("框选绘图区域"),
                    image: UIImage(systemName: "selection.pin.in.out")) {
                        [weak self] _ in self?.drawingGraph?.beginRegionSelection()
                })
                actions.append(UIAction(title: V3L("结束框选"),
                    image: UIImage(systemName: "checkmark.circle")) {
                        [weak self] _ in self?.drawingGraph?.endRegionSelection()
                })
                actions.append(UIAction(title: V3L("清空所选绘图"),
                    image: UIImage(systemName: "xmark.circle")) {
                        [weak self] _ in self?.drawingGraph?.clearSelections()
                })
            }
            more.menu = UIMenu(children: actions)
        }
        if document.identity.documentFormat == .markdown &&
           drawingDisplayFormat() == nil {
            var extras: [UIMenuElement] = [
                UIAction(title: V3L("全文译为简体中文"),
                    image: UIImage(systemName: "character.book.closed")) {
                    [weak self] _ in self?.openChineseTranslation()
                }
            ]
            if let diagrams = try? ImpressDiagramDocument.mermaidBlocks(
                in: document.sourceBytes), !diagrams.isEmpty {
                extras.append(UIAction(title: V3L("阅读 Mermaid 图形"),
                    image: UIImage(systemName: "point.3.connected.trianglepath.dotted")) {
                    [weak self] _ in self?.openDiagram(.mermaid)
                })
            }
            if (try? ImpressDiagramDocument.markmap(
                in: document.sourceBytes)) != nil {
                extras.append(UIAction(title: V3L("阅读 Markmap 思维导图"),
                    image: UIImage(systemName: "point.3.filled.connected.trianglepath.dotted")) {
                    [weak self] _ in self?.openDiagram(.markmap)
                })
            }
            more.menu = UIMenu(children: (more.menu?.children ?? []) + extras)
        }
        if sourceSectionDigest != nil &&
           document.identity.documentFormat == .markdown &&
           drawingDisplayFormat() == nil {
            // Only a single verified section anchor may be offered. When
            // the section has moved or changed, the action fails closed
            // instead of guessing a similarly titled paragraph.
            let section = UIAction(title: V3L("查看核实过的来源片段"),
                                   image: UIImage(systemName: "text.magnifyingglass")) {
                [weak self] _ in self?.openVerifiedSourceSection()
            }
            more.menu = UIMenu(children: (more.menu?.children ?? []) + [section])
        }
        discussion.tintColor = ImpressV3Appearance.navigationActionInk
        more.tintColor = ImpressV3Appearance.navigationActionInk
        navigationItem.rightBarButtonItems = [discussion, more]
    }

    @objc private func toggleProperties() {
        propertiesExpanded.toggle()
        let projection = ImpressFrontmatterReader.parse(document.markdown)
        updatePropertyPanel(projection)
    }

    /// A native typed Properties component. The web renderer only receives
    /// the YAML-free body; this view never converts typed values into writes.
    private func updatePropertyPanel(_ projection: ImpressFrontmatterReading) {
        let visible = document.identity.documentFormat == .markdown &&
            !isSourceMode && (!projection.fields.isEmpty || projection.diagnostic != nil)
        propertyPanel.isHidden = !visible
        guard visible else { return }
        propertyRows.arrangedSubviews.forEach {
            propertyRows.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, field) in projection.fields.enumerated() {
            let row = UIStackView()
            row.axis = .horizontal
            row.alignment = .top
            row.spacing = 10
            row.accessibilityIdentifier = "impress.notes.property." + String(index)
            let key = UILabel()
            key.text = field.name
            key.numberOfLines = 2
            key.font = ImpressV3Appearance.Typography.footnote
            key.adjustsFontForContentSizeCategory = true
            key.textColor = ImpressV3Appearance.secondaryText
            key.widthAnchor.constraint(equalToConstant: 116).isActive = true
            row.addArrangedSubview(key)
            if field.kind == .wikilink, let first = field.values.first,
               first.hasPrefix("[["), first.hasSuffix("]]") {
                let target = String(first.dropFirst(2).dropLast(2))
                    .components(separatedBy: "|").first ?? ""
                let link = UIButton(type: .system)
                link.contentHorizontalAlignment = .leading
                link.titleLabel?.numberOfLines = 0
                link.titleLabel?.font = ImpressV3Appearance.Typography.body
                link.titleLabel?.adjustsFontForContentSizeCategory = true
                link.setTitle(first, for: .normal)
                link.accessibilityIdentifier = "impress.notes.property-value." + field.name
                link.addAction(UIAction { [weak self] _ in
                    self?.followWikiLink(target)
                }, for: .touchUpInside)
                row.addArrangedSubview(link)
            } else {
                let value = UILabel()
                value.text = field.displayValue
                value.font = ImpressV3Appearance.Typography.body
                value.adjustsFontForContentSizeCategory = true
                value.textColor = ImpressV3Appearance.primaryText
                value.numberOfLines = 0
                value.accessibilityIdentifier = "impress.notes.property-value." + field.name
                row.addArrangedSubview(value)
            }
            propertyRows.addArrangedSubview(row)
        }
        if let diagnostic = projection.diagnostic {
            let notice = UILabel()
            notice.text = diagnostic + " · " + V3L("查看 Markdown 源码")
            notice.numberOfLines = 0
            notice.font = ImpressV3Appearance.Typography.footnote
            notice.adjustsFontForContentSizeCategory = true
            notice.textColor = ImpressV3Appearance.caution
            notice.accessibilityIdentifier = "impress.notes.properties-diagnostic"
            propertyRows.addArrangedSubview(notice)
        }
        propertyToggle.setTitle(
            (propertiesExpanded ? "⌄ " : "› ") + V3L("属性") +
                " (" + String(projection.fields.count) + ")",
            for: .normal)
        propertyToggle.accessibilityValue = propertiesExpanded ? V3L("已展开") : V3L("已折叠")
        propertyScroll.isHidden = !propertiesExpanded
        propertyScrollHeight?.constant = propertiesExpanded ?
            min(CGFloat(projection.fields.count + (projection.diagnostic == nil ? 0 : 1)) * 44 + 4,
                218) : 0
    }

    private func renderBody() {
        let properties = ImpressFrontmatterReader.parse(document.markdown)
        let singleScrollReading = !isSourceMode &&
            document.identity.documentFormat == .markdown &&
            drawingDisplayFormat() == nil
        // Markdown title, typed Properties and body now scroll as ONE WebKit
        // document. Separate UIKit header stays available in source/graph mode.
        contentTopWithHeader?.isActive = !singleScrollReading
        contentTopWithoutHeader?.isActive = singleScrollReading
        readerHeader.isHidden = singleScrollReading
        view.backgroundColor = singleScrollReading
            ? ImpressV3Appearance.surface : ImpressV3Appearance.page
        if !singleScrollReading { updatePropertyPanel(properties) }
        canvasHost.isHidden = true
        canvasGraph = nil
        drawingGraph = nil
        if isSourceMode {
            readingView.isHidden = false
            richView.isHidden = true
            readingView.text = document.markdown
            readingView.font = ImpressV3Appearance.Typography.code
            readingView.adjustsFontForContentSizeCategory = true
        } else if document.identity.documentFormat == .jsonCanvas {
            richView.isHidden = true
            readingView.isHidden = true
            canvasHost.isHidden = false
            do {
                let model = try ImpressCanvasDocument.parse(document.sourceBytes)
                let graph = try ImpressCanvasNativeView(source: model)
                canvasHost.subviews.forEach { $0.removeFromSuperview() }
                graph.translatesAutoresizingMaskIntoConstraints = false
                canvasHost.addSubview(graph)
                NSLayoutConstraint.activate([
                    graph.topAnchor.constraint(equalTo: canvasHost.topAnchor),
                    graph.bottomAnchor.constraint(equalTo: canvasHost.bottomAnchor),
                    graph.leadingAnchor.constraint(equalTo: canvasHost.leadingAnchor),
                    graph.trailingAnchor.constraint(equalTo: canvasHost.trailingAnchor)
                ])
                canvasGraph = graph
            } catch {
                canvasGraph = nil
                canvasHost.isHidden = true
                readingView.isHidden = false
                readingView.isEditable = false
                readingView.text = V3L("Canvas 绘制范围过大或结构不合法；未修改源文件。请查看源码以核查实际内容。") +
                    "\n\n" + error.localizedDescription
            }
        } else if let drawingFormat = drawingDisplayFormat() {
            richView.isHidden = true
            readingView.isHidden = true
            canvasHost.isHidden = false
            do {
                let scene = try ImpressExcalidrawScene.parse(document.sourceBytes,
                    format: drawingFormat)
                let graph = try ImpressExcalidrawNativeView(source: scene)
                canvasHost.subviews.forEach { $0.removeFromSuperview() }
                graph.translatesAutoresizingMaskIntoConstraints = false
                canvasHost.addSubview(graph)
                NSLayoutConstraint.activate([
                    graph.topAnchor.constraint(equalTo: canvasHost.topAnchor),
                    graph.bottomAnchor.constraint(equalTo: canvasHost.bottomAnchor),
                    graph.leadingAnchor.constraint(equalTo: canvasHost.leadingAnchor),
                    graph.trailingAnchor.constraint(equalTo: canvasHost.trailingAnchor)
                ])
                drawingGraph = graph
            } catch {
                drawingGraph = nil
                canvasHost.isHidden = true
                readingView.isHidden = false
                readingView.isEditable = false
                readingView.font = ImpressV3Appearance.Typography.code
                readingView.text = V3L("绘图数据不合法或范围过大；未修改源文件。") +
                    "\n\n" + error.localizedDescription
            }
        } else if document.identity.documentFormat != .markdown {
            richView.isHidden = true
            readingView.isHidden = false
            readingView.isEditable = false
            readingView.font = ImpressV3Appearance.Typography.code
            readingView.text = V3L("此复合文件的图形阅读器尚未完成，不会执行未知插件、模板或脚本。以下是只读原始数据：") +
                "\n\n" + document.markdown
        } else {
            readingView.isHidden = true
            richView.isHidden = false
            // Existing bundled MarkdownView/markdown-it renders tables,
            // fenced code, lists and headings without exposing a mutable text
            // buffer. Blocking external images avoids silent HTTP requests
            // from a private note. A future local-attachment bridge must
            // independently validate each file under the scoped Vault URL.
            // MarkdownKit-rich rendering runs inside a WKWebView. Literal
            // HTML from shared notes is inert in this read-only projection,
            // while raw source remains untouched and inspectable separately.
            let fallback: String
            if properties.state == .invalid || properties.state == .unsupported {
                fallback = ImVaultSafetyProjection.withoutUntrustedImages(properties.body)
            } else {
                fallback = ImVaultSafetyProjection.withoutUntrustedImages(
                    ImVaultSafetyProjection.withCalloutHeadings(
                        ImVaultSafetyProjection.withWikiLinks(properties.body)))
            }
            let safeMarkdown = preparedMarkdown ?? fallback
            // Only the prepared projection has excluded all ordinary image
            // URLs and can allow data: image embeds. The initial fallback
            // prohibits all images, including remote images.
            // Bundled MarkdownView's original CSS hardcodes white surfaces.
            // A central trusted media-query stylesheet adapts live to the
            // system appearance without re-reading or modifying Vault files.
            richView.load(markdown: safeMarkdown,
                          enableImage: preparedMarkdown != nil,
                          css: ImpressV3Appearance.markdownReaderCSS,
                          documentTitle: documentTitleText,
                          properties: properties,
                          sourceDigest: document.digest)
        }
        readingView.textAlignment = .left
    }

    @objc private func toggleSource() {
        isSourceMode.toggle()
        renderBody()
    }

    /// A drawing selection stays tied to the exact Vault, SHA-256 and element
    /// IDs that the user saw. Preview never implies a model upload.
    @objc private func reviewSelectedDrawing() {
        guard let format = drawingDisplayFormat(),
              let ids = drawingGraph?.selectedIDs, !ids.isEmpty else {
            let alert = UIAlertController(title: V3L("请先选择绘图元素"),
                message: V3L("轻点元素选择范围。选材本身不发送任何数据或图像。"),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
            present(alert, animated: true)
            return
        }
        let expectedDigest = document.digest
        withVerifiedLiveDocument { [weak self] latest in
            guard let self else { return }
            guard latest.digest == expectedDigest,
                  (latest.identity.documentFormat == format ||
                   (latest.identity.documentFormat == .markdown &&
                    format == .excalidrawMarkdown &&
                    ImpressObsidianDrawingEnvelope.isSupportedDrawing(
                        latest.sourceBytes))) else {
                self.showVaultError(V3L("绘图来源已变化，请重新选择"),
                    error: ImVaultSyncFailure.conflict)
                return
            }
            do {
                let scene = try ImpressExcalidrawScene.parse(latest.sourceBytes,
                    format: format)
                // A shape's bound text is a separate Excalidraw element.
                // Offer the same explicit scope choice even without groups,
                // otherwise a user cannot include the text they can see.
                let hasBoundText = scene.elements.contains { element in
                    element.isActive && element.type == "text" &&
                        (element.containerId.map { ids.contains($0) } ?? false)
                }
                let hasRelated = hasBoundText || scene.elements.contains {
                    ids.contains($0.id) && ($0.type == "frame" ||
                        !($0.groupIds ?? []).isEmpty)
                }
                if hasRelated {
                    let ask = UIAlertController(title: V3L("确认绘图选材范围"),
                        message: V3L("额外包含同组、嵌套框架或绑定文字会扩大材料，请明确选择。"),
                        preferredStyle: .actionSheet)
                    ask.addAction(UIAlertAction(title: V3L("仅选中的元素"),
                        style: .default) { [weak self] _ in
                        self?.previewDrawingSelection(latest, scene: scene, ids: ids,
                            expandGroups: false)
                    })
                    ask.addAction(UIAlertAction(title: V3L("包括关联元素（组、框架、绑定文字）"),
                        style: .default) { [weak self] _ in
                        self?.previewDrawingSelection(latest, scene: scene, ids: ids,
                            expandGroups: true)
                    })
                    ask.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
                    ask.popoverPresentationController?.sourceView = self.view
                    self.present(ask, animated: true)
                } else {
                    self.previewDrawingSelection(latest, scene: scene, ids: ids,
                        expandGroups: false)
                }
            } catch {
                self.showVaultError(V3L("无法验证当前绘图"), error: error)
            }
        }
    }

    private func previewDrawingSelection(_ live: ImVaultRawDocument,
                                         scene: ImpressExcalidrawScene,
                                         ids: Set<String>, expandGroups: Bool) {
        do {
            let selection = try scene.selection(ids: ids, expandGroups: expandGroups)
            let json = try selection.textContextJSON()
            let targetKey = "note:" + ImVaultDigest.sha256(
                Data((live.identity.vaultID + "\n" +
                      live.identity.relativePath).utf8))
            // Existing source-scoped ID list is deliberately reused without
            // migrating old Chat/backup records; sourceFormat disambiguates.
            let reference = WCDBV3ChatContextReference(
                stableIdentity: targetKey, sourceRevision: live.digest,
                excerpt: json, sourceFormat: "excalidraw-structure",
                selectedCanvasNodeIDs: selection.elementIDs.sorted())
            let page = UIViewController()
            page.title = V3L("绘图材料完整预览")
            page.view.backgroundColor = ImpressV3Appearance.page
            let preview = UITextView()
            preview.translatesAutoresizingMaskIntoConstraints = false
            preview.isEditable = false
            preview.isSelectable = true
            preview.isScrollEnabled = true
            preview.font = ImpressV3Appearance.Typography.code
            preview.adjustsFontForContentSizeCategory = true
            preview.backgroundColor = ImpressV3Appearance.surface
            preview.textColor = ImpressV3Appearance.primaryText
            preview.text = V3L("来源 Vault：") + live.identity.vaultID +
                "\n" + live.identity.relativePath + "\nSHA-256: " + live.digest +
                "\n" + V3L("选择元素数：") + String(selection.elements.count) +
                "\n" + V3L("仅传输所选文字/图形结构，不包含图片像素。") +
                "\n\n" + json
            preview.accessibilityIdentifier = "impress.excalidraw.material-preview"
            page.view.addSubview(preview)
            NSLayoutConstraint.activate([
                preview.topAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.topAnchor),
                preview.bottomAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.bottomAnchor),
                preview.leadingAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.leadingAnchor),
                preview.trailingAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.trailingAnchor)
            ])
            page.navigationItem.rightBarButtonItem = UIBarButtonItem(
                primaryAction: UIAction(title: V3L("确认范围并加入 Chat"),
                    image: UIImage(systemName: "bubble.left")) { [weak self] _ in
                    guard let self,
                          ImVaultReadOnlyProbe.shared.authorizedVaultID ==
                              live.identity.vaultID else { return }
                    do {
                        let repo = try ImpressV3ReviewEnvironment.repository()
                        let chat = ImpressAINativeChatViewController(
                            question: V3L("来源绘图：") + live.identity.relativePath,
                            answer: nil, repository: repo,
                            sourceKey: targetKey, sourceVersion: live.digest,
                            noteIdentity: live.identity, initialMaterials: [reference])
                        self.navigationController?.pushViewController(chat, animated: true)
                    } catch {
                        self.showVaultError(V3L("无法保存绘图材料"), error: error)
                    }
                })
            page.navigationItem.rightBarButtonItem?.accessibilityIdentifier =
                "impress.excalidraw.confirm-material"
            navigationController?.pushViewController(page, animated: true)
        } catch {
            showVaultError(V3L("所选绘图范围无效"), error: error)
        }
    }

    /// A selection from JSON Canvas requires live Vault re-read, exact node
    /// IDs and a complete material preview. It never reads unselected files.
    @objc private func reviewSelectedCanvas() {
        guard document.identity.documentFormat == .jsonCanvas,
              let chosenIDs = canvasGraph?.selectedIDs, !chosenIDs.isEmpty else {
            let alert = UIAlertController(title: V3L("请先选择画布节点"),
                message: V3L("轻点要讨论的节点；选择本身不发送数据。"),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
            present(alert, animated: true)
            return
        }
        let originalDigest = document.digest
        withVerifiedLiveDocument { [weak self] latest in
            guard let self else { return }
            guard latest.digest == originalDigest,
                  latest.identity.documentFormat == .jsonCanvas else {
                self.showVaultError(V3L("Canvas 来源已变化，请重新选材"),
                    error: ImVaultSyncFailure.conflict)
                return
            }
            do {
                let model = try ImpressCanvasDocument.parse(latest.sourceBytes)
                let includesGroup = model.nodes.contains {
                    chosenIDs.contains($0.id) && $0.type == "group"
                }
                if includesGroup {
                    let ask = UIAlertController(title: V3L("确认画布范围"),
                        message: V3L("分组可能包含其他节点。仅所选节点与包含组内节点是不同的发送范围，请明确选择。"),
                        preferredStyle: .actionSheet)
                    ask.addAction(UIAlertAction(title: V3L("仅选择的节点"),
                        style: .default) { [weak self] _ in
                        self?.previewCanvasSelection(latest, model: model,
                            ids: chosenIDs, expandGroups: false)
                    })
                    ask.addAction(UIAlertAction(title: V3L("同时包含分组内的节点"),
                        style: .default) { [weak self] _ in
                        self?.previewCanvasSelection(latest, model: model,
                            ids: chosenIDs, expandGroups: true)
                    })
                    ask.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
                    ask.popoverPresentationController?.sourceView = self.view
                    ask.popoverPresentationController?.sourceRect = CGRect(
                        x: self.view.bounds.midX, y: self.view.bounds.midY,
                        width: 1, height: 1)
                    self.present(ask, animated: true)
                } else {
                    self.previewCanvasSelection(latest, model: model,
                        ids: chosenIDs, expandGroups: false)
                }
            } catch {
                self.showVaultError(V3L("无法核实画布节点"), error: error)
            }
        }
    }

    private func previewCanvasSelection(_ live: ImVaultRawDocument,
                                        model: ImpressCanvasDocument,
                                        ids: Set<String>, expandGroups: Bool) {
        do {
            let selection = try model.selection(nodeIDs: ids,
                includeGroupMembers: expandGroups)
            guard selection.nodes.allSatisfy(\.isKnownType) else {
                throw ImpressCanvasError.invalidDocument
            }
            let json = try selection.serializedJSON()
            let targetKey = "note:" + ImVaultDigest.sha256(
                Data((live.identity.vaultID + "\n" +
                      live.identity.relativePath).utf8))
            let reference = WCDBV3ChatContextReference(
                stableIdentity: targetKey, sourceRevision: live.digest,
                excerpt: json, sourceFormat: "json-canvas",
                selectedCanvasNodeIDs: selection.nodeIDs.sorted())
            let page = UIViewController()
            page.title = V3L("画布材料完整预览")
            page.view.backgroundColor = ImpressV3Appearance.page
            let preview = UITextView()
            preview.translatesAutoresizingMaskIntoConstraints = false
            preview.isEditable = false
            preview.isSelectable = true
            preview.isScrollEnabled = true
            preview.font = ImpressV3Appearance.Typography.code
            preview.adjustsFontForContentSizeCategory = true
            preview.backgroundColor = ImpressV3Appearance.surface
            preview.textColor = ImpressV3Appearance.primaryText
            preview.text = V3L("真实 Vault：") + live.identity.vaultID +
                "\n" + live.identity.relativePath +
                "\nSHA-256: " + live.digest +
                "\n" + V3L("选择节点数：") + String(selection.nodes.count) +
                "\n\n" + json
            preview.accessibilityIdentifier = "impress.canvas.material-preview"
            page.view.addSubview(preview)
            NSLayoutConstraint.activate([
                preview.topAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.topAnchor),
                preview.bottomAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.bottomAnchor),
                preview.leadingAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.leadingAnchor),
                preview.trailingAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.trailingAnchor)
            ])
            page.navigationItem.rightBarButtonItem = UIBarButtonItem(
                primaryAction: UIAction(title: V3L("确认范围并加入 Chat"),
                    image: UIImage(systemName: "bubble.left")) { [weak self] _ in
                        guard let self,
                              ImVaultReadOnlyProbe.shared.authorizedVaultID ==
                                  live.identity.vaultID else {
                            return
                        }
                        do {
                            let repo = try ImpressV3ReviewEnvironment.repository()
                            let chat = ImpressAINativeChatViewController(
                                question: V3L("来源画布：") + live.identity.relativePath,
                                answer: nil, repository: repo,
                                sourceKey: targetKey, sourceVersion: live.digest,
                                noteIdentity: live.identity, initialMaterials: [reference])
                            self.navigationController?.pushViewController(
                                chat, animated: true)
                        } catch {
                            self.showVaultError(V3L("无法保存所选画布材料"), error: error)
                        }
                })
            page.navigationItem.rightBarButtonItem?.accessibilityIdentifier =
                "impress.canvas.confirm-material"
            navigationController?.pushViewController(page, animated: true)
        } catch {
            showVaultError(V3L("无法使用选定画布范围"), error: error)
        }
    }

    private func openVerifiedSourceSection() {
        guard let digest = sourceSectionDigest else { return }
        withVerifiedLiveDocument { [weak self] latest in
            guard let self else { return }
            let matches = ImpressAISectionExtractor.sections(in: latest.markdown).filter {
                ImVaultDigest.sha256(Data($0.text.utf8)) == digest
            }
            guard matches.count == 1, let match = matches.first else {
                // Old/changed/duplicate sections are not precise locators.
                // The complete note is still available; do not force a
                // made-up heading or try to restore removed text from Chat.
                self.showVaultError(V3L("来源片段无法可靠定位"),
                                    error: ImVaultSyncFailure.conflict)
                return
            }
            let page = UIViewController()
            page.title = V3L("已核实来源片段")
            page.view.backgroundColor = ImpressV3Appearance.page
            let view = UITextView()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.backgroundColor = ImpressV3Appearance.surface
            view.textColor = ImpressV3Appearance.primaryText
            view.font = ImpressV3Appearance.Typography.body
            view.adjustsFontForContentSizeCategory = true
            view.isEditable = false
            view.isSelectable = true
            view.accessibilityIdentifier = "impress.notes.verified-source-section"
            // Excerpt content is the current, authorized source Markdown
            // itself, not a model paraphrase or a truncated heading match.
            view.text = V3L("来源笔记：") + latest.identity.relativePath +
                "\n" + V3L("章节：") + match.heading +
                "\nSHA-256: " + digest + "\n\n" + match.text
            page.view.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(
                    equalTo: page.view.safeAreaLayoutGuide.topAnchor),
                view.bottomAnchor.constraint(
                    equalTo: page.view.safeAreaLayoutGuide.bottomAnchor),
                view.leadingAnchor.constraint(
                    equalTo: page.view.safeAreaLayoutGuide.leadingAnchor),
                view.trailingAnchor.constraint(
                    equalTo: page.view.safeAreaLayoutGuide.trailingAnchor)
            ])
            self.navigationController?.pushViewController(page, animated: true)
        }
    }

    private func followWikiLink(_ rawTarget: String) {
        let withoutHeading = rawTarget.components(separatedBy: "#").first ?? rawTarget
        let withoutBlock = withoutHeading.components(separatedBy: "^").first ?? withoutHeading
        let target = withoutBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\\"),
              !target.contains(":"), !target.split(separator: "/").contains("..") else {
            showVaultError("不安全的内部笔记链接", error: ImVaultSyncFailure.unsafePath)
            return
        }
        // A known Canvas/Excalidraw extension opens its existing native reader;
        // only extensionless Obsidian links default to Markdown.
        let normalized = ImVaultDocumentFormat.detect(relativePath: target) == nil
            ? target + ".md" : target
        do {
            // Link resolution uses the identity of the authorized Vault,
            // never a title-only match against a different Vault or old WCDB.
            let indexed = try ImVaultPrivateStore.loadIndex(vaultID: document.identity.vaultID)
            let matches = indexed.filter { note in
                let relative = note.identity.relativePath
                if target.contains("/") {
                    return relative.compare(normalized, options: .caseInsensitive) == .orderedSame
                }
                return URL(fileURLWithPath: relative).lastPathComponent
                    .compare(normalized, options: .caseInsensitive) == .orderedSame
            }
            guard matches.count == 1, let note = matches.first else {
                let alert = UIAlertController(title: "无法打开内部链接",
                    message: matches.isEmpty
                        ? "目标笔记不存在或索引需要刷新。"
                        : "存在同名笔记。请使用包含完整相对目录的 Obsidian 链接。",
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
                present(alert, animated: true)
                return
            }
            ImVaultReadSync.shared.read(note.identity) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case let .success(next):
                    self.navigationController?.pushViewController(
                        ImVaultDocumentController(document: next), animated: true)
                case let .failure(error):
                    self.showVaultError("目标笔记读取失败", error: error)
                }
            }
        } catch {
            showVaultError("内部链接索引不可用", error: error)
        }
    }

    /// A diagram entry never trusts a cached projection: the full Vault
    /// identity/version and structural source ranges are checked again.
    private func openDiagram(_ kind: ImpressDiagramKind) {
        guard document.identity.documentFormat == .markdown else { return }
        withVerifiedLiveDocument { [weak self] current in
            guard let self else { return }
            do {
                let candidates: [ImpressDiagramDocument]
                switch kind {
                case .mermaid:
                    candidates = try ImpressDiagramDocument.mermaidBlocks(
                        in: current.sourceBytes)
                case .markmap:
                    candidates = [try ImpressDiagramDocument.markmap(
                        in: current.sourceBytes)]
                }
                guard !candidates.isEmpty else { throw ImpressDiagramError.empty }
                if candidates.count == 1 {
                    self.navigationController?.pushViewController(
                        ImpressDiagramReaderController(source: current,
                            diagram: candidates[0]), animated: true)
                } else {
                    let alert = UIAlertController(title: V3L("选择 Mermaid 图形"),
                        message: V3L("每个图形保留独立的源文件范围。"),
                        preferredStyle: .actionSheet)
                    for (index, item) in candidates.enumerated() {
                        alert.addAction(UIAlertAction(title: "Mermaid " +
                            String(index + 1) + " · UTF8 " + String(item.startUTF8),
                            style: .default) { [weak self] _ in
                            self?.navigationController?.pushViewController(
                                ImpressDiagramReaderController(source: current,
                                    diagram: item), animated: true)
                        })
                    }
                    alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
                    alert.popoverPresentationController?.sourceView = self.view
                    self.present(alert, animated: true)
                }
            } catch {
                self.showVaultError(V3L("无法读取图形来源"), error: error)
            }
        }
    }

    @objc private func generateAIQuestions() {
        guard document.identity.documentFormat == .markdown,
              drawingDisplayFormat() == nil else {
            showVaultError(V3L("不支持从此复合格式直接生成问题"),
                error: ImVaultSyncFailure.unsupportedComplexWrite)
            return
        }
        withVerifiedLiveDocument { [weak self] latest in
            self?.navigationController?.pushViewController(
                ImpressAIQuestionGenerationViewController(document: latest), animated: true)
        }
    }

    @objc private func openChineseTranslation() {
        guard document.identity.documentFormat == .markdown,
              drawingDisplayFormat() == nil else { return }
        withVerifiedLiveDocument { [weak self] latest in
            guard let self else { return }
            // Read-only presentation from a just-verified Vault snapshot.
            // Translation never writes the source, any card or local history.
            let reader = ImpressNoteChineseTranslationReader(
                sourceTitle: latest.identity.relativePath, original: latest.markdown)
            let screen = UIHostingController(rootView: reader)
            screen.title = V3L("中文译文")
            self.navigationController?.pushViewController(screen, animated: true)
        }
    }

    @objc private func openNativeNoteDiscussion() {
        if document.identity.documentFormat == .jsonCanvas {
            reviewSelectedCanvas()
            return
        }
        if drawingDisplayFormat() != nil {
            reviewSelectedDrawing()
            return
        }
        withVerifiedLiveDocument { [weak self] latest in
            guard let self else { return }
            // The Vault was read back immediately before this user action.
            // Preparing the browser draft never grants write access or sends
            // data; the user must tap Insert and then Send in DeepSeek.
            let markdown = latest.markdown.utf8.count <= 8_000
                ? latest.markdown : nil
            let prompt = ImpressAIChatPromptSelection.selectedTemplate()?.content
                ?? UserDefaults.standard.string(forKey: "kSystemPrompt")
            let payload = ImpressV3DeepSeekHandoff.makeNotePayload(
                title: latest.identity.relativePath,
                markdown: markdown, userPrompt: prompt)
            let web = ImWebViewController.forReviewHandoff(text: payload)
            let navigation = ImNavigationViewController(rootViewController: web)
            navigation.modalPresentationStyle = .fullScreen
            self.present(navigation, animated: true)
        }
    }

    @objc private func openLinkedCards() {
        guard ImVaultReadOnlyProbe.shared.authorizedVaultID ==
                document.identity.vaultID else {
            showVaultError(V3L("Vault 授权已失效"),
                error: ImVaultCoreError.invalidVaultIdentity)
            return
        }
        do {
            let repository = try ImpressV3ReviewEnvironment.repository()
            let collection = ImpressV3CardCollectionViewController(
                repository: repository, sourceIdentity: document.identity)
            navigationController?.pushViewController(collection, animated: true)
        } catch {
            showVaultError(V3L("无法查询关联卡片"), error: error)
        }
    }

    /// Explicit reverse check only. Source key v2 is file-level evidence,
    /// NOT a claim that an unrelated paragraph changed the card's answer.
    @objc private func checkLinkedCardChanges() {
        guard ImVaultReadOnlyProbe.shared.authorizedVaultID == document.identity.vaultID else {
            showVaultError(V3L("Vault 授权已失效"), error: ImVaultSyncFailure.wrongVault)
            return
        }
        ImVaultReadSync.shared.read(document.identity) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.showVaultError(V3L("来源笔记读取失败"), error: error)
            case .success(let source):
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let repo = try ImpressV3ReviewEnvironment.repository()
                        let related = try await repo.listRelatedCards(for: source.identity)
                        let oldHashes: [(WCDBV3ManagedCard, String)] = related.compactMap {
                            card in
                            guard let key = card.sourceNotePath,
                                  let original = try? ImpressBatchSourceKey.documentDigest(for: key),
                                  original != source.digest else { return nil }
                            // An unchanged, unique v3 section needs NO manual
                            // review merely because a different chapter or
                            // cosmetic file metadata changed. Legacy v1/v2 and
                            // missing/ambiguous section anchors remain honest
                            // file-level manual checks, never guessed matches.
                            guard !ImpressAINoteCardLink.verifiedSectionUnchanged(
                                sourceKey: key, currentMarkdown: source.markdown)
                            else { return nil }
                            return (card, original)
                        }
                        if oldHashes.isEmpty {
                            let message = UIAlertController(
                                title: V3L("没有需要核查的已记录变化"),
                                message: V3L("关联原卡没有已记录的来源版本差异，或旧卡缺少来源摘要。不能据此证明笔记和卡片始终一致。"),
                                preferredStyle: .alert)
                            message.addAction(UIAlertAction(title: V3L("确定"), style: .default))
                            self.present(message, animated: true)
                            return
                        }
                        let picker = UIAlertController(title: V3L("核查关联原卡"),
                            message: V3L("只看到文件版本变化，无法假装精确定位相关章节。请选择一张原卡进行人工核对。"),
                            preferredStyle: .actionSheet)
                        for (card, digest) in oldHashes.prefix(16) {
                            picker.addAction(UIAlertAction(
                                title: String(card.question.prefix(52)),
                                style: .default) { [weak self] _ in
                                self?.navigationController?.pushViewController(
                                    ImpressNoteSourceImpactController(
                                        document: source, cardID: card.cardID,
                                        previousDigest: digest, repository: repo),
                                    animated: true)
                            })
                        }
                        picker.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
                        picker.popoverPresentationController?.sourceView = self.view
                        picker.popoverPresentationController?.sourceRect = CGRect(
                            x: self.view.bounds.midX, y: self.view.bounds.midY,
                            width: 1, height: 1)
                        self.present(picker, animated: true)
                    } catch { self.showVaultError(V3L("无法查询关联卡片"), error: error) }
                }
            }
        }
    }

    @objc private func editDraft() {
        guard document.identity.documentFormat.allowsGenericMarkdownDraft,
              drawingDisplayFormat() == nil else {
            showVaultError(V3L("此格式仅允许阅读和选材"),
                error: ImVaultSyncFailure.unsupportedComplexWrite)
            return
        }
        withVerifiedLiveDocument { [weak self] latest in
            guard let self else { return }
            do {
                try ImVaultDraftEntry.open(live: latest, presenter: self)
            } catch { self.showVaultError(V3L("无法打开独立草稿"), error: error) }
        }
    }

    private func showVaultError(_ title: String, error: Error) {
        let alert = UIAlertController(title: title,
                                      message: error.localizedDescription,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        present(alert, animated: true)
    }
}

/// Shared safe editor entry for note/Chat/duplex flows.
@MainActor
enum ImVaultDraftEntry {
    /// One entry for Chat, note detail and duplex proposal. A second revision
    /// requires an explicit choice; no automatic rewrite of stale draft bytes.
    static func open(live: ImVaultRawDocument, presenter: UIViewController) throws {
        let prior = try ImVaultPrivateStore.loadDraft(identity: live.identity)
        func push(_ draft: ImVaultDraft) {
            presenter.navigationController?.pushViewController(
                ImVaultDraftEditorController(draft: draft), animated: true)
        }
        guard let prior else {
            push(try ImVaultDraft(identity: live.identity,
                baseText: live.markdown, baseRawData: live.sourceBytes))
            return
        }
        guard prior.hasChanges, prior.baseDigest != live.digest,
              ImVaultDigest.sha256(prior.proposedBytes) == live.digest else {
            push(prior)
            return
        }
        let picker = UIAlertController(title: V3L("已应用的笔记草稿"),
            message: V3L("原草稿与当前来源一致。可查看旧草稿，或明确创建下一次修订；会保留旧批准快照与历史回执。"),
            preferredStyle: .alert)
        picker.addAction(UIAlertAction(title: V3L("查看旧草稿"), style: .default) { _ in
            push(prior)
        })
        picker.addAction(UIAlertAction(title: V3L("建立下一版笔记草稿"),
            style: .default) { _ in
            // Re-read after the user confirms; the File Provider might have
            // changed while the alert was displayed.
            ImVaultReadSync.shared.read(live.identity) { result in
                do {
                    let latest = try result.get()
                    guard latest.identity == live.identity,
                          latest.digest == live.digest else {
                        throw ImVaultSyncFailure.conflict
                    }
                    let fresh = try ImVaultPrivateStore.startFreshDraft(
                        afterApplied: prior, live: latest)
                    push(fresh)
                } catch {
                    let failed = UIAlertController(title: V3L("无法建立新草稿"),
                        message: error.localizedDescription, preferredStyle: .alert)
                    failed.addAction(UIAlertAction(title: V3L("确定"), style: .default))
                    presenter.present(failed, animated: true)
                }
            }
        })
        picker.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        presenter.present(picker, animated: true)
    }
}

// A low-weight, manual reverse check. Only records an explicit "unaffected"
/// decision for this original card. It does NOT modify Obsidian source, score
/// a review, fabricate section-level linkage or silently mark other cards.
@MainActor
enum ImpressSourceImpactCardRevisionGate {
    /// A note's current content is evidence, not authority to silently edit
    /// its original cards. Only the user-edited card input is applied, with
    /// exact source identity/version and independent WCDB content CAS.
    static func refreshedInput(approved: WCDBV3CardInput,
                               original: WCDBV3CardContent,
                               oldSourceKey: String,
                               currentNote: ImVaultRawDocument,
                               expectedCurrentDigest: String) throws -> WCDBV3CardInput {
        // A no-op Save is NOT an implicit "source did not affect this card"
        // acknowledgement. Use the explicit unaffected action for that.
        let contentChanged = approved.question != original.question ||
            approved.answerText != original.answerText ||
            approved.choices != original.choices ||
            approved.correctIndices != original.correctIndices ||
            approved.cardType != original.cardType ||
            approved.imageData != original.imageData
        guard contentChanged, approved.cardID == original.cardID,
              approved.sourceNotePath == oldSourceKey,
              original.sourceNotePath == oldSourceKey,
              (try? ImpressBatchSourceKey.decode(oldSourceKey)) == currentNote.identity,
              ImVaultDigest.sha256(currentNote.sourceBytes) == currentNote.digest,
              currentNote.digest == expectedCurrentDigest else {
            throw ImVaultSyncFailure.conflict
        }
        let linked = try ImpressBatchSourceKey.encode(
            currentNote.identity, documentDigest: currentNote.digest)
        // A once-trustworthy section anchor is deliberately downgraded to
        // file-level after material change; never pretend a changed section
        // still has the old hash.
        return WCDBV3CardInput(cardID: approved.cardID,
            question: approved.question, answerText: approved.answerText,
            choices: approved.choices, correctIndices: approved.correctIndices,
            cardType: approved.cardType, imageData: approved.imageData,
            sourceNotePath: linked)
    }
}

@MainActor
final class ImpressNoteSourceImpactController: UIViewController {
    private let document: ImVaultRawDocument
    private let cardID: UUID
    private let previousDigest: String
    private let repository: ReviewWCDBRepository
    private let reading = UITextView()
    private let markUnaffected = UIButton(type: .system)
    private let editOriginalCard = UIButton(type: .system)
    private var ready = false
    // Prevent a second source-impact decision while the confirmed digest
    // readback and card CAS are still in flight.
    private var unaffectedApprovalPending = false
    // The first editor tap starts an asynchronous WCDB/source-read window.
    // Lock both competing source decisions until that window resolves.
    private var originalEditorOpening = false
    private var observedRevision: Int?
    private var originalSourceKey: String?

    init(document: ImVaultRawDocument, cardID: UUID, previousDigest: String,
         repository: ReviewWCDBRepository) {
        self.document = document
        self.cardID = cardID
        self.previousDigest = previousDigest
        self.repository = repository
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("原卡来源核查")
        view.backgroundColor = ImpressV3Appearance.page
        reading.translatesAutoresizingMaskIntoConstraints = false
        reading.font = ImpressV3Appearance.Typography.body
        reading.adjustsFontForContentSizeCategory = true
        reading.isEditable = false
        reading.isSelectable = true
        reading.textColor = ImpressV3Appearance.primaryText
        reading.backgroundColor = ImpressV3Appearance.surface
        reading.accessibilityIdentifier = "impress.notes.source-impact.full-text"
        ImpressV3Appearance.styleQuietButton(markUnaffected,
            title: V3L("已核对：修改不影响这张原卡"), symbol: "checkmark.shield")
        ImpressV3Appearance.styleQuietButton(editOriginalCard,
            title: V3L("核查后修订这张原卡"), symbol: "square.and.pencil")
        editOriginalCard.translatesAutoresizingMaskIntoConstraints = false
        editOriginalCard.accessibilityIdentifier = "impress.notes.source-impact.edit-original"
        editOriginalCard.isEnabled = false
        editOriginalCard.addTarget(self, action: #selector(openOriginalCardEditor),
            for: .touchUpInside)
        markUnaffected.translatesAutoresizingMaskIntoConstraints = false
        markUnaffected.accessibilityIdentifier = "impress.notes.source-impact.unaffected"
        markUnaffected.isEnabled = false
        markUnaffected.addTarget(self, action: #selector(confirmUnaffected),
                                 for: .touchUpInside)
        view.addSubview(reading)
        view.addSubview(editOriginalCard)
        view.addSubview(markUnaffected)
        NSLayoutConstraint.activate([
            reading.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                                          constant: 8),
            reading.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                                              constant: 12),
            reading.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                                               constant: -12),
            reading.bottomAnchor.constraint(equalTo: editOriginalCard.topAnchor,
                                             constant: -12),
            editOriginalCard.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            editOriginalCard.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            editOriginalCard.bottomAnchor.constraint(equalTo: markUnaffected.topAnchor,
                                                       constant: -6),
            editOriginalCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            markUnaffected.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            markUnaffected.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            markUnaffected.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            markUnaffected.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
        Task { await loadCard() }
    }

    private func loadCard() async {
        do {
            guard let card = try await repository.content(for: cardID),
                  let queue = try await repository.fetchQueueCandidates()
                    .first(where: { $0.cardID == cardID }),
                  let key = card.sourceNotePath,
                  (try? ImpressBatchSourceKey.decode(key)) == document.identity,
                  (try? ImpressBatchSourceKey.documentDigest(for: key)) == previousDigest
            else { throw ImVaultSyncFailure.conflict }
            observedRevision = card.contentRevision
            originalSourceKey = key
            reading.text = V3L("仅能确认文件级来源变化；请阅读当前完整笔记及原卡，再决定是否受影响。") +
                "\n\nVault ID: " + document.identity.vaultID +
                "\n" + V3L("来源：") + document.identity.relativePath +
                "\n" + V3L("原来源 SHA-256：") + previousDigest +
                "\n" + V3L("新来源 SHA-256：") + document.digest +
                "\n\ncardID: " + cardID.uuidString +
                "\n\n" + V3L("题目：") + card.question +
                "\n\n" + V3L("答案：") + (card.answerText ?? "") +
                "\n\n" + V3L("当前笔记完整 Markdown：") + "\n" + document.markdown
            ready = true
            markUnaffected.isEnabled = true
            editOriginalCard.isEnabled = true
        } catch {
            reading.text = error.localizedDescription
            markUnaffected.isEnabled = false
            editOriginalCard.isEnabled = false
        }
    }


    @objc private func openOriginalCardEditor() {
        guard ready, !unaffectedApprovalPending, !originalEditorOpening,
              presentedViewController == nil,
              let observedRevision, let oldKey = originalSourceKey,
              ImVaultReadOnlyProbe.shared.authorizedVaultID == document.identity.vaultID
        else { return }
        originalEditorOpening = true
        editOriginalCard.isEnabled = false
        markUnaffected.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let content = try await repository.content(for: cardID),
                      content.contentRevision == observedRevision,
                      content.sourceNotePath == oldKey,
                      (try? ImpressBatchSourceKey.decode(oldKey)) == document.identity
                else { throw ImVaultSyncFailure.conflict }
                let correct = Set((content.correctIndices ?? "")
                    .split(separator: ",").compactMap { Int($0) })
                let choices: [ImpressV3CardDraft.Choice] =
                    (content.choices ?? "").isEmpty ? [.init(), .init()] :
                    (content.choices ?? "").components(separatedBy: "\n")
                        .enumerated().map { i, name in
                            .init(text: name, isCorrect: correct.contains(i))
                        }
                let draft = ImpressV3CardDraft(
                    kind: CardType(rawValue: content.cardType) ?? .standard,
                    question: content.question, answer: content.answerText ?? "",
                    choices: choices, allowsMultipleCorrect: correct.count > 1,
                    imageData: content.imageData, sourceNotePath: oldKey)
                let editor = ImpressV3CardComposerViewController(
                    draft: draft, editingCardID: cardID)
                editor.onSave = { [weak self] approved in
                    guard let self, self.ready,
                          ImVaultReadOnlyProbe.shared.authorizedVaultID ==
                          self.document.identity.vaultID else {
                        throw ImVaultSyncFailure.wrongVault
                    }
                    // Recheck the exact File Provider note AFTER editing and
                    // BEFORE updating WCDB. No stale source acknowledgement.
                    let current: ImVaultRawDocument = try await withCheckedThrowingContinuation {
                        (continuation: CheckedContinuation<ImVaultRawDocument, Error>) in
                        ImVaultReadSync.shared.read(self.document.identity) { value in
                            continuation.resume(with: value)
                        }
                    }
                    guard let actual = try await self.repository.content(for: self.cardID),
                          actual.contentRevision == observedRevision,
                          actual.sourceNotePath == oldKey,
                          let queue = try await self.repository.fetchQueueCandidates()
                            .first(where: { $0.cardID == self.cardID }) else {
                        throw ImVaultSyncFailure.conflict
                    }
                    guard ImVaultReadOnlyProbe.shared.authorizedVaultID ==
                          self.document.identity.vaultID else {
                        throw ImVaultSyncFailure.wrongVault
                    }
                    let authorized = try ImpressSourceImpactCardRevisionGate.refreshedInput(
                        approved: approved, original: actual, oldSourceKey: oldKey,
                        currentNote: current, expectedCurrentDigest: self.document.digest)
                    try await self.repository.updateManagedCard(authorized,
                        expectedRevision: queue.revision,
                        expectedContentRevision: observedRevision, origin: .manual)
                    self.ready = false
                    self.editOriginalCard.isEnabled = false
                    self.markUnaffected.isEnabled = false
                    self.navigationItem.prompt = V3L(
                        "原卡已按人工修订保存；cardID 和 FSRS 历史保留。返回可继续复习。")
                }
                let nav = ImNavigationViewController(rootViewController: editor)
                nav.modalPresentationStyle = .pageSheet
                nav.sheetPresentationController?.detents = [.large()]
                present(nav, animated: true) { [weak self] in
                    guard let self else { return }
                    self.originalEditorOpening = false
                    let eligible = self.ready && !self.unaffectedApprovalPending
                    self.editOriginalCard.isEnabled = eligible
                    self.markUnaffected.isEnabled = eligible
                }
            } catch {
                originalEditorOpening = false
                presentError(error)
            }
        }
    }

    @objc private func confirmUnaffected() {
        guard ready, !unaffectedApprovalPending, !originalEditorOpening,
              presentedViewController == nil,
              let originalRevision = observedRevision,
              let oldKey = originalSourceKey else { return }
        // Consent starts with the first tap, NOT after the final alert action:
        // two rapid taps must never queue distinct approvals for one source.
        unaffectedApprovalPending = true
        markUnaffected.isEnabled = false
        editOriginalCard.isEnabled = false
        let alert = UIAlertController(title: V3L("确认不影响原卡？"),
            message: V3L("仅更新这张原卡的已核实来源摘要；题目、答案和 FSRS 评分不变。修改仍需版本核验，其他卡片不受影响。"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel) {
            [weak self] _ in
            guard let self else { return }
            self.unaffectedApprovalPending = false
            self.markUnaffected.isEnabled = self.ready
            self.editOriginalCard.isEnabled = self.ready
        })
        alert.addAction(UIAlertAction(title: V3L("确认不影响"), style: .default) {
            [weak self] _ in
            guard let self, self.ready, self.unaffectedApprovalPending else { return }
            // The original SHA/identity and WCDB CAS remain mandatory after
            // explicit consent. No second authorization starts in parallel.
            ImVaultReadSync.shared.read(self.document.identity) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.presentError(error)
                case .success(let latest):
                    Task {
                        do {
                            guard latest.digest == self.document.digest,
                                  let content = try await self.repository.content(for: self.cardID),
                                  content.contentRevision == originalRevision,
                                  content.sourceNotePath == oldKey,
                                  let queue = try await self.repository.fetchQueueCandidates()
                                    .first(where: { $0.cardID == self.cardID }) else {
                                throw ImVaultSyncFailure.conflict
                            }
                            let newest = try ImpressBatchSourceKey.encode(
                                self.document.identity, documentDigest: latest.digest)
                            try await self.repository.updateManagedCard(
                                WCDBV3CardInput(cardID: self.cardID,
                                    question: content.question,
                                    answerText: content.answerText, choices: content.choices,
                                    correctIndices: content.correctIndices,
                                    cardType: content.cardType,
                                    imageData: content.imageData, sourceNotePath: newest),
                                // FSRS may advance while the user reads; only
                                // content/source changes invalidate approval.
                                expectedRevision: queue.revision,
                                expectedContentRevision: originalRevision, origin: .manual)
                            self.ready = false
                            self.unaffectedApprovalPending = false
                            self.markUnaffected.isEnabled = false
                            self.editOriginalCard.isEnabled = false
                            let done = UIAlertController(
                                title: V3L("已确认这张原卡不受影响"),
                                message: V3L("仅更新来源核对版本，保留原卡、答案、FSRS 历史及源笔记。"),
                                preferredStyle: .alert)
                            done.addAction(UIAlertAction(title: V3L("确定"),
                                style: .default) { [weak self] _ in
                                self?.navigationController?.popViewController(animated: true)
                            })
                            self.present(done, animated: true)
                        } catch { self.presentError(error) }
                    }
                }
            }
        })
        present(alert, animated: true)
    }

    private func presentError(_ error: Error) {
        unaffectedApprovalPending = false
        markUnaffected.isEnabled = ready
        editOriginalCard.isEnabled = ready
        let alert = UIAlertController(title: V3L("来源核查失败"),
            message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        present(alert, animated: true)
    }
}

/// Source-preserving local editor. Each edit persists a private draft and
/// cannot change Obsidian's actual Markdown until full P0-5 approval.
@MainActor
final class ImVaultDraftEditorController: UIViewController, UITextViewDelegate {
    private var draft: ImVaultDraft
    private let sourceView = UITextView()
    private let persistenceQueue = DispatchQueue(label: "impress.vault.draft.persist",
                                                 qos: .utility)
    private var pendingAutosave: DispatchWorkItem?
    private var autosaveFailure: String?

    init(draft: ImVaultDraft) {
        self.draft = draft
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(draft:) required") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("编辑私有草稿")
        view.backgroundColor = ImpressV3Appearance.page
        let notice = UILabel()
        notice.text = V3L("只保存在 Impress · 不直接修改 Obsidian")
        notice.textColor = ImpressV3Appearance.secondaryText
        notice.textAlignment = .center
        notice.font = ImpressV3Appearance.Typography.footnote
        notice.adjustsFontForContentSizeCategory = true
        notice.numberOfLines = 0
        notice.translatesAutoresizingMaskIntoConstraints = false

        sourceView.translatesAutoresizingMaskIntoConstraints = false
        sourceView.backgroundColor = ImpressV3Appearance.surface
        sourceView.textColor = ImpressV3Appearance.primaryText
        sourceView.font = ImpressV3Appearance.Typography.code
        sourceView.adjustsFontForContentSizeCategory = true
        sourceView.layer.cornerRadius = ImpressV3Appearance.Radius.field
        sourceView.text = draft.editedText
        sourceView.textContainerInset = UIEdgeInsets(top: 15, left: 15,
                                                    bottom: 24, right: 15)
        sourceView.delegate = self
        sourceView.isEditable = true
        ImpressSpeechAccessory.install(on: sourceView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(flushDraftBeforeBackground),
            name: UIApplication.willResignActiveNotification, object: nil)
        view.addSubview(notice)
        view.addSubview(sourceView)
        NSLayoutConstraint.activate([
            notice.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            notice.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            notice.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            sourceView.topAnchor.constraint(equalTo: notice.bottomAnchor, constant: 8),
            sourceView.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: ImpressV3Appearance.Metrics.screenInset),
            sourceView.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -ImpressV3Appearance.Metrics.screenInset),
            sourceView.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -ImpressV3Appearance.Metrics.compactInset)
        ])
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: V3L("查看差异"), style: .plain, target: self,
                            action: #selector(showDiff)),
            UIBarButtonItem(title: V3L("保存草稿"), style: .plain, target: self,
                            action: #selector(saveDraftNow))
        ]
    }

    func textViewDidChange(_ textView: UITextView) {
        do {
            try draft.update(textView.text ?? "")
            scheduleDraftAutosave()
        } catch {
            // The visible text must not diverge from the last validated draft.
            textView.text = draft.editedText
            presentError("草稿超过安全大小限制", error)
        }
    }

    /// Debounce full Markdown JSON writes. Never enqueue a multi-megabyte
    /// encoding operation for every key stroke on a mobile keyboard.
    private func scheduleDraftAutosave() {
        pendingAutosave?.cancel()
        let snapshot = draft
        let work = DispatchWorkItem { [weak self] in
            do {
                try ImVaultPrivateStore.saveDraft(snapshot)
                DispatchQueue.main.async { self?.autosaveFailure = nil }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self?.autosaveFailure = message
                    self?.navigationItem.prompt = "草稿自动保存失败 · 请使用保存草稿"
                }
            }
        }
        pendingAutosave = work
        persistenceQueue.asyncAfter(deadline: .now() + .milliseconds(650), execute: work)
    }

    /// A best-effort synchronous flush is important when iOS suspends a
    /// backgrounded app before a queued autosave has had a chance to run.
    @objc private func flushDraftBeforeBackground() {
        pendingAutosave?.cancel()
        do {
            try ImVaultPrivateStore.saveDraft(draft)
            autosaveFailure = nil
        } catch {
            autosaveFailure = error.localizedDescription
            navigationItem.prompt = "草稿保存失败 · 请检查可用存储空间"
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        pendingAutosave?.cancel()
        flushDraftBeforeBackground()
        super.viewWillDisappear(animated)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pendingAutosave?.cancel()
    }

    @objc private func saveDraftNow() {
        pendingAutosave?.cancel()
        do {
            try ImVaultPrivateStore.saveDraft(draft)
            autosaveFailure = nil
            navigationItem.prompt = nil
            let notice = UIAlertController(title: V3L("草稿已保存"),
                message: "仅存储在 Impress 私有目录，没有修改 Obsidian 文件。",
                preferredStyle: .alert)
            notice.addAction(UIAlertAction(title: V3L("确定"), style: .default))
            present(notice, animated: true)
        } catch { presentError("保存草稿失败", error) }
    }

    @objc private func showDiff() {
        do { try ImVaultPrivateStore.saveDraft(draft) }
        catch { presentError("无法持久化草稿", error); return }
        ImVaultReadSync.shared.read(draft.identity) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .success(source):
                let decision = self.draft.decision(against: source.sourceBytes)
                if decision == .conflict {
                    self.presentError("源文件已被其他应用修改",
                                      ImVaultSyncFailure.conflict)
                    return
                }
                let changes = ImVaultDiff.summary(
                    base: self.draft.byteFaithfulBaseText, edited: self.draft.byteFaithfulEditedText,
                    maximumLines: 200)
                self.navigationController?.pushViewController(
                    ImVaultDiffController(draft: self.draft, summary: changes.text,
                                          canApprove: changes.complete && decision == .safeToWrite),
                    animated: true)
            case let .failure(error):
                self.presentError("无法检查 Obsidian 当前版本", error)
            }
        }
    }

    private func presentError(_ title: String, _ error: Error) {
        let alert = UIAlertController(title: title,
                                      message: error.localizedDescription,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        present(alert, animated: true)
    }
}

// A verified local File Provider response is not evidence of iCloud server upload.
// Keep the receipt precise for each outcome, and never imply that a no-op wrote bytes.
@MainActor
enum ImVaultWriteReceiptText {
    static func present(_ result: Result<ImVaultCommitOutcome, Error>,
                        testCopy: Bool) -> (title: String, detail: String) {
        switch result {
        case .success(.unchanged):
            return (V3L("内容未变化"),
                    V3L("原文与拟保存内容一致，没有写入文件，也没有修改复习数据。"))
        case .success(.alreadyApplied):
            return (V3L("内容已存在"),
                    V3L("文件内容已经与提案一致，没有重复写入，也没有再次追加内容。云端同步尚未核实。"))
        case .success(.written(_)):
            let destination = testCopy
                ? V3L("已写入独立测试副本") : V3L("源文件已在本机写入")
            return (destination,
                    V3L("重新验证了原文件版本，写前已保留恢复副本，写后本机回读字节一致。File Provider 的本机写入成功不代表云端 iCloud 已完成同步。"))
        case .failure(let error):
            return (V3L("原文件未确认写入"),
                    error.localizedDescription + "\n" +
                    V3L("请检查冲突、授权及草稿状态，不要重复覆盖，也不要把保存草稿当成原文件已更新。"))
        }
    }
}

@MainActor
final class ImVaultDiffController: UIViewController {
    private let draft: ImVaultDraft
    private let summary: String
    private let canApprove: Bool

    init(draft: ImVaultDraft, summary: String, canApprove: Bool) {
        self.draft = draft
        self.summary = summary
        self.canApprove = canApprove
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(draft:summary:) required") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "源文件差异"
        view.backgroundColor = ImpressV3Appearance.page
        let text = UITextView()
        text.isEditable = false
        text.isSelectable = true
        text.font = ImpressV3Appearance.Typography.compactCode
        text.adjustsFontForContentSizeCategory = true
        text.textColor = ImpressV3Appearance.primaryText
        text.backgroundColor = ImpressV3Appearance.surface
        text.layer.cornerRadius = ImpressV3Appearance.Radius.field
        // The user approves an exact Vault file and its observed source
        // revision. Display this even for a short one-line diff.
        let targetHeader = "Vault ID: " + draft.identity.vaultID +
            "\n" + V3L("目标文件：") + draft.identity.relativePath
        let versionHeader = "SHA-256: " + draft.baseDigest
        text.text = targetHeader + "\n" + versionHeader + "\n\n" + summary
        text.accessibilityIdentifier = "impress.vault.diff.full-preview"
        text.textContainerInset = UIEdgeInsets(top: ImpressV3Appearance.Metrics.fieldPadding, left: ImpressV3Appearance.Metrics.fieldPadding,
                                             bottom: ImpressV3Appearance.Metrics.fieldPadding, right: ImpressV3Appearance.Metrics.fieldPadding)
        text.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(text)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: ImpressV3Appearance.Metrics.compactInset),
            text.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -ImpressV3Appearance.Metrics.compactInset),
            text.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: ImpressV3Appearance.Metrics.screenInset),
            text.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -ImpressV3Appearance.Metrics.screenInset)
        ])
        let save = UIBarButtonItem(title: "确认写回", style: .plain,
                                   target: self, action: #selector(confirmWrite))
        // Production stays read-only. Debug QA can only enable this action
        // when the authorized folder is the explicitly named disposable copy.
        save.isEnabled = canApprove && ImVaultGuardedWrite.productionWriteEnabled
        navigationItem.rightBarButtonItem = save
        #if DEBUG
        if canApprove && !ImVaultGuardedWrite.productionWriteEnabled {
            navigationItem.prompt = V3L("真机 QA 仅支持独立的测试 Vault 副本")
            ImVaultGuardedWrite.checkQAVaultEligibility(for: draft.identity) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(true):
                    save.title = V3L("测试副本写回")
                    save.isEnabled = true
                    self.navigationItem.prompt = V3L("仅限测试副本；原始 Vault 仍保持只读")
                case .success(false):
                    self.navigationItem.prompt = V3L("正式 Vault 不可写入；当前草稿安全保存。仅独立 QA 测试副本允许写回。")
                case .failure(let error):
                    self.navigationItem.prompt = error.localizedDescription
                }
            }
        }
        #endif
    }

    @objc private func confirmWrite() {
        guard canApprove else { return }
        #if DEBUG
        let qaCopyRequested = !ImVaultGuardedWrite.productionWriteEnabled
        #else
        let qaCopyRequested = false
        #endif
        let targetContext = "Vault ID: " + draft.identity.vaultID +
            "\n" + V3L("目标文件：") + draft.identity.relativePath +
            "\nSHA-256: " + draft.baseDigest + "\n\n"
        let alert = UIAlertController(
            title: qaCopyRequested ? V3L("确认修改独立测试副本？") :
                                     V3L("确认修改 Obsidian 源文件？"),
            message: targetContext + (qaCopyRequested
                ? V3L("仅操作「文件」中名称为 Impress-Write-Test-Vault 的独立副本。正式 Vault 不可写入。将重新核对原文 SHA-256，保存恢复副本后再尝试写入；请先自行复制重要笔记。")
                : V3L("将重新验证源文件 SHA-256，并先保存私有恢复副本。如果出现版本冲突会拒绝覆盖。")),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: qaCopyRequested ? V3L("确认测试副本写回") :
                                                              V3L("确认写回"),
                                      style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.navigationItem.rightBarButtonItem?.isEnabled = false
            ImVaultGuardedWrite.commitAuthorized(draft: self.draft,
                                                  userConfirmedDiff: true,
                                                  deviceQATestCopyConfirmed: qaCopyRequested) { result in
                self.navigationItem.rightBarButtonItem?.isEnabled = true
                let receipt = ImVaultWriteReceiptText.present(
                    result, testCopy: qaCopyRequested)
                let response = UIAlertController(title: receipt.title,
                    message: receipt.detail, preferredStyle: .alert)
                response.addAction(UIAlertAction(title: V3L("确定"), style: .default))
                self.present(response, animated: true)
            }
        })
        present(alert, animated: true)
    }
}




// MARK: - V1.1 Excalidraw offline read-only spatial viewport

/// Native, local geometry projection for safe viewing/selection of Excalidraw
/// elements. Unlike the official Excalidraw editor, this does not edit files
/// or evaluate user-provided JavaScript/SVG/HTML. Images and custom fonts
/// require a separately authorized resource bridge; they are NOT displayed
/// or sent as image pixels by this projection.
@MainActor
final class ImpressExcalidrawNativeView: UIScrollView, UIScrollViewDelegate {
    private let artboard = UIView()
    private var controls: [String: UIButton] = [:]
    private(set) var selectedIDs = Set<String>()
    private var selectionPan: UIPanGestureRecognizer?
    private var selectionStart: CGPoint?
    private let selectionOutline = CAShapeLayer()
    private(set) var selectingRegion = false
    let source: ImpressExcalidrawScene

    init(source: ImpressExcalidrawScene) throws {
        self.source = source
        super.init(frame: .zero)
        accessibilityIdentifier = "impress.excalidraw.native-viewport"
        backgroundColor = .systemGroupedBackground
        isAccessibilityElement = false
        shouldGroupAccessibilityChildren = false
        delegate = self
        minimumZoomScale = 0.25
        maximumZoomScale = 3
        alwaysBounceHorizontal = true
        alwaysBounceVertical = true

        let elements = source.elements.filter(\.isActive)
        let minX = elements.map(\.x).min() ?? 0
        let minY = elements.map(\.y).min() ?? 0
        let maxX = elements.map { $0.x + $0.width }.max() ?? 320
        let maxY = elements.map { $0.y + $0.height }.max() ?? 400
        let width = max(320, maxX - minX + 96)
        let height = max(400, maxY - minY + 96)
        guard width.isFinite, height.isFinite,
              width <= 12_000, height <= 12_000,
              width * height <= 20_000_000 else {
            throw ImpressExcalidrawReadError.tooLarge
        }
        artboard.frame = CGRect(x: 0, y: 0, width: width, height: height)
        // Keep the scene's authored palette in either iOS appearance.
        let canvasBackground = Self.color(source.appState?.viewBackgroundColor) ?? .white
        artboard.backgroundColor = canvasBackground
        artboard.isAccessibilityElement = false
        artboard.shouldGroupAccessibilityChildren = false
        addSubview(artboard)
        contentSize = artboard.bounds.size

        // Keep the serialized paint order. UIKit zPosition is needed because
        // some bound text overlays must sit just above their own container.
        // Never put every text node above every later shape.
        let elementOrder = Dictionary(uniqueKeysWithValues:
            elements.enumerated().map { ($0.element.id, $0.offset) })
        for (order, element) in elements.enumerated() {
            let rect = CGRect(x: element.x - minX + 48,
                              y: element.y - minY + 48,
                              width: max(1, element.width),
                              height: max(1, element.height))
            let control = UIButton(type: .custom)
            control.frame = rect
            control.layer.zPosition = CGFloat(order)
            control.backgroundColor = .clear
            control.setTitleColor(.label, for: .normal)
            control.titleLabel?.font = .preferredFont(forTextStyle: .body)
            control.titleLabel?.adjustsFontForContentSizeCategory = true
            control.titleLabel?.numberOfLines = 0
            control.contentHorizontalAlignment = .leading
            control.contentVerticalAlignment = .top
            control.contentEdgeInsets = UIEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
            control.isAccessibilityElement = true
            control.accessibilityTraits = .button
            control.accessibilityIdentifier = "impress.excalidraw.element." + element.id
            control.accessibilityHint = V3L("选择或取消绘图元素；不会自动发送")
            control.accessibilityLabel = element.text ?? (element.type + " · " + element.id)

            let stroke = Self.color(element.strokeColor) ?? UIColor.secondaryLabel
            if let outline = Self.path(for: element, size: rect.size) {
                let shape = CAShapeLayer()
                shape.path = outline.cgPath
                shape.strokeColor = stroke.cgColor
                shape.fillColor = (Self.color(element.backgroundColor) ?? UIColor.clear).cgColor
                // Excalidraw opacity applies to both the line and fill,
                // not just the fill. Compositing them as one layer also avoids
                // alpha accumulating where stroke and fill overlap.
                shape.opacity = Float((element.opacity ?? 100) / 100)
                shape.lineWidth = CGFloat(min(24, max(0.5, element.strokeWidth ?? 1.5)))
                // Match native SVG stroke style semantics; artwork color and
                // opacity remain authored rather than inherited system tint.
                switch element.strokeStyle {
                case "dashed": shape.lineDashPattern = [8, 8]
                case "dotted":
                    shape.lineDashPattern = [1, 6]
                    shape.lineCap = .round
                default: shape.lineDashPattern = nil
                }
                control.layer.addSublayer(shape)
                if element.type == "arrow", let points = element.points,
                   points.count >= 2 {
                    // Preserve independent start/end arrowhead geometry.
                    // Their paint is not affected by the line dash pattern,
                    // and their layers rotate together with the parent element.
                    let width = shape.lineWidth
                    let ends: [(String, String?, [Double], [Double])] = [
                        ("start", element.startArrowhead, points[0], points[1]),
                        ("end", element.endArrowhead,
                         points[points.count - 1], points[points.count - 2])
                    ]
                    for (side, style, tip, neighbor) in ends {
                        guard let style, tip.count >= 2, neighbor.count >= 2,
                              let head = Self.arrowheadPath(
                                style: style,
                                tip: CGPoint(x: tip[0], y: tip[1]),
                                neighbor: CGPoint(x: neighbor[0], y: neighbor[1]),
                                strokeWidth: width) else { continue }
                        let decoration = CAShapeLayer()
                        decoration.name = "impress.excalidraw.arrowhead." + side
                        decoration.path = head.path.cgPath
                        decoration.strokeColor = stroke.cgColor
                        decoration.fillColor = head.filled
                            ? stroke.cgColor : UIColor.clear.cgColor
                        decoration.lineWidth = width
                        decoration.lineJoin = .round
                        decoration.lineCap = .round
                        decoration.opacity = shape.opacity
                        control.layer.addSublayer(decoration)
                    }
                }
            }
            if element.type == "text" {
                // UIKit UIButton title layout clipped multiline/bound labels
                // and ignored the original drawing's font size and alignment.
                // A dedicated UILabel preserves the visible source glyphs.
                let label = UILabel()
                label.text = element.text ?? ""
                label.numberOfLines = 0
                label.textAlignment = element.textAlign == "center" ? .center :
                    (element.textAlign == "right" ? .right : .left)
                let size = CGFloat(element.fontSize ?? 20)
                label.font = element.fontFamily == 3 ?
                    UIFont.monospacedSystemFont(ofSize: size, weight: .regular) :
                    UIFont.systemFont(ofSize: size, weight: .regular)
                label.textColor = Self.readableInk(Self.color(element.strokeColor),
                                                  on: canvasBackground)
                // Excalidraw stores a per-element lineHeight multiplier; the
                // default system UILabel leading loses authored multiline rhythm.
                let line = CGFloat(element.lineHeight ?? 1.25) * size
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = label.textAlignment
                paragraph.minimumLineHeight = line
                paragraph.maximumLineHeight = line
                label.attributedText = NSAttributedString(string: element.text ?? "",
                    attributes: [
                        .font: label.font as Any,
                        .foregroundColor: label.textColor as Any,
                        .paragraphStyle: paragraph
                    ])
                label.alpha = CGFloat(element.opacity ?? 100) / 100
                label.isUserInteractionEnabled = false
                let textWidth = max(1, rect.width - 6)
                let measured = label.sizeThatFits(
                    CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
                // Use actual glyph height for vertical alignment. Using the
                // full box height made middle/bottom behave as top alignment.
                let textHeight = max(1, measured)
                let top = element.verticalAlign == "middle" ?
                    max(3, (rect.height - textHeight) / 2) :
                    (element.verticalAlign == "bottom" ?
                        max(3, rect.height - textHeight - 3) : 3)
                label.frame = CGRect(x: 3, y: top, width: textWidth, height: textHeight)
                control.clipsToBounds = false
                control.addSubview(label)
                // A bound text stays above its *own* container only, while
                // respecting later authored occluding shapes.
                if let containerID = element.containerId,
                   let containerOrder = elementOrder[containerID] {
                    control.layer.zPosition = CGFloat(containerOrder) + 0.25
                }
            } else if element.type == "image" {
                if let picture = Self.localImage(for: element, in: source),
                   let placement = ImpressExcalidrawImageViewport.placement(
                       displayWidth: Double(rect.width),
                       displayHeight: Double(rect.height),
                       naturalWidth: Double(picture.size.width),
                       naturalHeight: Double(picture.size.height),
                       crop: element.crop, scale: element.scale) {
                    // Read-only, no external resource: clip the decoded local bitmap
                    // to the author's viewport, then flip the *viewport* about its
                    // center before the existing outer element rotation is applied.
                    // This matches DiagramReader's SVG crop/flip semantics.
                    let clipped = UIView(frame: control.bounds)
                    clipped.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    clipped.clipsToBounds = true
                    clipped.isUserInteractionEnabled = false
                    let flipped = UIView(frame: clipped.bounds)
                    flipped.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    flipped.transform = CGAffineTransform(
                        scaleX: CGFloat(placement.flipX),
                        y: CGFloat(placement.flipY))
                    let imageView = UIImageView(image: picture)
                    imageView.frame = CGRect(x: CGFloat(placement.x), y: CGFloat(placement.y),
                        width: CGFloat(placement.width), height: CGFloat(placement.height))
                    imageView.contentMode = .scaleToFill
                    imageView.alpha = CGFloat((element.opacity ?? 100) / 100)
                    imageView.isUserInteractionEnabled = false
                    flipped.addSubview(imageView)
                    clipped.addSubview(flipped)
                    control.addSubview(clipped)
                } else {
                    control.backgroundColor = UIColor.tertiarySystemFill
                    control.setTitle(V3L("图片未就绪：不加载外链"), for: .normal)
                    control.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
                }
            } else if !["rectangle", "ellipse", "diamond", "frame",
                       "line", "arrow", "freedraw"].contains(element.type) {
                control.setTitle(element.type, for: .normal)
            }
            if let angle = element.angle, angle.isFinite {
                control.transform = CGAffineTransform(rotationAngle: CGFloat(angle))
            }
            control.addAction(UIAction { [weak self] _ in
                self?.toggle(element.id)
            }, for: .touchUpInside)
            artboard.addSubview(control)
            controls[element.id] = control
        }
        artboard.accessibilityElements = source.elements.filter(\.isActive)
            .compactMap { controls[$0.id] }
        selectionOutline.fillColor = UIColor.clear.cgColor
        selectionOutline.strokeColor = ImpressV3Appearance.accent.cgColor
        selectionOutline.lineDashPattern = [6, 4]
        selectionOutline.lineWidth = 1.5
        selectionOutline.zPosition = 1_000
        artboard.layer.addSublayer(selectionOutline)
        let recognizer = UIPanGestureRecognizer(target: self,
            action: #selector(dragSelectionRegion(_:)))
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
        recognizer.isEnabled = false
        artboard.addGestureRecognizer(recognizer)
        selectionPan = recognizer
    }

    required init?(coder: NSCoder) { fatalError("init(source:) required") }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { artboard }

    /// Whole-picture approval is an explicit user action, never the default
    /// Chat material scope. Every selected ID is independently revalidated.
    func selectAllActive() {
        endRegionSelection()
        selectedIDs = Set(controls.keys)
        refreshSelections()
    }

    func clearSelections() {
        endRegionSelection()
        selectedIDs.removeAll()
        refreshSelections()
    }

    func beginRegionSelection() {
        selectingRegion = true
        isScrollEnabled = false
        selectionPan?.isEnabled = true
        accessibilityValue = V3L("区域选择模式：在画布中拖动一个矩形")
    }

    func endRegionSelection() {
        selectingRegion = false
        isScrollEnabled = true
        selectionPan?.isEnabled = false
        selectionStart = nil
        selectionOutline.path = nil
        accessibilityValue = nil
    }

    /// Use the center point of each transformed element to avoid importing a
    /// visually adjacent, unapproved shape touched by one rectangle pixel.
    func selectElements(in rect: CGRect) {
        guard rect.width >= 12, rect.height >= 12 else { return }
        for (id, button) in controls where rect.contains(
            CGPoint(x: button.frame.midX, y: button.frame.midY)) {
            selectedIDs.insert(id)
        }
        refreshSelections()
    }

    @objc private func dragSelectionRegion(_ recognizer: UIPanGestureRecognizer) {
        let cursor = recognizer.location(in: artboard)
        switch recognizer.state {
        case .began:
            selectionStart = cursor
        case .changed, .ended:
            guard let start = selectionStart else { return }
            let frame = CGRect(x: min(start.x, cursor.x),
                y: min(start.y, cursor.y),
                width: abs(cursor.x - start.x), height: abs(cursor.y - start.y))
            selectionOutline.path = UIBezierPath(rect: frame).cgPath
            if recognizer.state == .ended {
                selectElements(in: frame)
                endRegionSelection()
            }
        case .cancelled, .failed:
            endRegionSelection()
        default: break
        }
    }

    private func toggle(_ id: String) {
        if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
        refreshSelections()
    }

    private func refreshSelections() {
        for (key, button) in controls {
            let selected = selectedIDs.contains(key)
            button.layer.borderColor = selected
                ? ImpressV3Appearance.accent.cgColor : UIColor.clear.cgColor
            button.layer.borderWidth = selected ? 3 : 0
            button.accessibilityValue = selected ? V3L("已选择") : V3L("未选择")
        }
    }

    /// Decode only already-embedded, source-authorized raster bytes. A
    /// strict pixel bound prevents adversarial dimensions from allocating
    /// an unbounded bitmap. External paths, SVG, remote URLs and web scripts are inert.
    private static func localImage(for element: ImpressExcalidrawElement,
                                   in scene: ImpressExcalidrawScene) -> UIImage? {
        guard let id = element.fileId, let file = scene.files?[id],
              let value = file.dataURL else { return nil }
        let prefix: String
        if value.hasPrefix("data:image/png;base64,") {
            prefix = "data:image/png;base64,"
        } else if value.hasPrefix("data:image/jpeg;base64,") {
            prefix = "data:image/jpeg;base64,"
        } else {
            return nil
        }
        let encoded = String(value.dropFirst(prefix.count))
        guard encoded.utf8.count <= 4 * 1_024 * 1_024,
              let bytes = Data(base64Encoded: encoded),
              bytes.count <= 3 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as NSDictionary?,
              let pixelWidth = properties.object(forKey: kCGImagePropertyPixelWidth) as? Int,
              let pixelHeight = properties.object(forKey: kCGImagePropertyPixelHeight) as? Int,
              pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= 4_096, pixelHeight <= 4_096,
              pixelWidth * pixelHeight <= 4_000_000,
              let raster = CGImageSourceCreateImageAtIndex(source, 0, nil)
              else { return nil }
        return UIImage(cgImage: raster)
    }

    private static func readableInk(_ preferred: UIColor?, on canvas: UIColor) -> UIColor {
        guard let preferred else { return .black }
        func luminance(_ c: UIColor) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0
            var b: CGFloat = 0, a: CGFloat = 0
            guard c.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0.5 }
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        let ink = luminance(preferred), background = luminance(canvas)
        // Only override effectively invisible authored colors.
        return abs(ink - background) < 0.28 ? (background < 0.5 ? .white : .black)
                                             : preferred
    }

    private static func color(_ hex: String?) -> UIColor? {
        guard let hex, hex.first == "#", hex.count == 7,
              let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    /// Supports authored Excalidraw endpoints without a second renderer or
    /// default V marker. Unknown styles safely omit only that decoration.
    private static func arrowheadPath(style: String, tip: CGPoint,
                                      neighbor: CGPoint, strokeWidth: CGFloat)
        -> (path: UIBezierPath, filled: Bool)? {
        let dx = tip.x - neighbor.x
        let dy = tip.y - neighbor.y
        let norm = hypot(dx, dy)
        guard norm.isFinite, norm > 0.001 else { return nil }
        let direction = CGVector(dx: dx / norm, dy: dy / norm)
        let normal = CGVector(dx: -direction.dy, dy: direction.dx)
        let length = min(24, max(10, 10 + strokeWidth * 2))
        let halfWidth = length * 0.46
        let base = CGPoint(x: tip.x - direction.dx * length,
                           y: tip.y - direction.dy * length)
        let left = CGPoint(x: base.x + normal.dx * halfWidth,
                           y: base.y + normal.dy * halfWidth)
        let right = CGPoint(x: base.x - normal.dx * halfWidth,
                            y: base.y - normal.dy * halfWidth)
        let path = UIBezierPath()
        switch style {
        case "arrow":
            path.move(to: left)
            path.addLine(to: tip)
            path.addLine(to: right)
            return (path, false)
        case "triangle", "triangle_outline":
            path.move(to: tip)
            path.addLine(to: left)
            path.addLine(to: right)
            path.close()
            return (path, style == "triangle")
        case "dot", "circle", "circle_outline":
            let radius = length * 0.30
            path.append(UIBezierPath(ovalIn: CGRect(
                x: tip.x - radius, y: tip.y - radius,
                width: radius * 2, height: radius * 2)))
            return (path, style == "dot" || style == "circle")
        case "bar":
            path.move(to: CGPoint(
                x: tip.x + normal.dx * halfWidth,
                y: tip.y + normal.dy * halfWidth))
            path.addLine(to: CGPoint(
                x: tip.x - normal.dx * halfWidth,
                y: tip.y - normal.dy * halfWidth))
            return (path, false)
        case "diamond", "diamond_outline":
            let far = CGPoint(x: tip.x - direction.dx * length * 2,
                              y: tip.y - direction.dy * length * 2)
            path.move(to: tip)
            path.addLine(to: left)
            path.addLine(to: far)
            path.addLine(to: right)
            path.close()
            return (path, style == "diamond")
        default:
            return nil
        }
    }

    private static func path(for element: ImpressExcalidrawElement,
                             size: CGSize) -> UIBezierPath? {
        let bounds = CGRect(origin: .zero, size: size)
        switch element.type {
        case "rectangle":
            let radius: CGFloat
            switch element.roundness?.type {
            case 3:
                // Official ADAPTIVE_RADIUS = 32 pt, bounded by half the
                // narrow side (optional saved radius is respected).
                let authored = element.roundness?.value ?? 32
                radius = CGFloat(min(max(0, authored),
                                     min(element.width, element.height) / 2))
            case 1, 2:
                // Legacy / PROPORTIONAL_RADIUS = 1/4 of shorter edge.
                radius = 0.25 * min(bounds.width, bounds.height)
            default:
                // An explicit or absent sharp rectangle must remain sharp.
                radius = 0
            }
            return UIBezierPath(roundedRect: bounds, cornerRadius: radius)
        case "frame":
            return UIBezierPath(rect: bounds)
        case "ellipse":
            return UIBezierPath(ovalIn: bounds)
        case "diamond":
            let path = UIBezierPath()
            path.move(to: CGPoint(x: bounds.midX, y: 0))
            path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.midY))
            path.addLine(to: CGPoint(x: bounds.midX, y: bounds.maxY))
            path.addLine(to: CGPoint(x: 0, y: bounds.midY))
            path.close()
            return path
        case "line", "arrow", "freedraw":
            guard let points = element.points, let first = points.first,
                  first.count >= 2 else { return nil }
            let path = UIBezierPath()
            path.move(to: CGPoint(x: first[0], y: first[1]))
            for point in points.dropFirst() where point.count >= 2 {
                path.addLine(to: CGPoint(x: point[0], y: point[1]))
            }
            // Arrowheads are independent layers: a dashed line must never
            // turn a filled terminal triangle into several dotted fragments.
            return path
        default: return nil
        }
    }
}

// MARK: - V1.1 read-only JSON Canvas native spatial visualization

/// One spatial projection of the original JSON Canvas, with no JavaScript,
/// network, plugin execution, automatic relayout or file write capability.
/// Relative node positions, dimensions, group containment, edges and source
/// order are preserved. A global offset only allows negative coordinates to
/// appear within a UIKit scrollable view.
@MainActor
final class ImpressCanvasNativeView: UIScrollView, UIScrollViewDelegate {
    let source: ImpressCanvasDocument
    private let artboard = UIView()
    private var buttons: [String: UIButton] = [:]
    private var originalNodeColors: [String: UIColor] = [:]
    private(set) var selectedIDs = Set<String>()
    var onSelectionChanged: ((Set<String>) -> Void)?

    init(source: ImpressCanvasDocument) throws {
        self.source = source
        super.init(frame: .zero)
        backgroundColor = .systemGroupedBackground
        accessibilityIdentifier = "impress.canvas.native-viewport"
        isAccessibilityElement = false
        shouldGroupAccessibilityChildren = false
        delegate = self
        minimumZoomScale = 0.25
        maximumZoomScale = 2.5
        bouncesZoom = true
        alwaysBounceHorizontal = true
        alwaysBounceVertical = true
        showsHorizontalScrollIndicator = true
        showsVerticalScrollIndicator = true

        let all = source.nodes
        let minX = all.map { Double($0.x) }.min() ?? 0
        let minY = all.map { Double($0.y) }.min() ?? 0
        let maxX = all.map { Double($0.x) + Double($0.width) }.max() ?? 320
        let maxY = all.map { Double($0.y) + Double($0.height) }.max() ?? 380
        let width = maxX - minX + 96
        let height = maxY - minY + 96
        // The file remains readable in source mode when an enormous canvas
        // would exhaust UIKit memory. No silent clipping or downsampling.
        guard width.isFinite, height.isFinite,
              width <= 12_000, height <= 12_000 else {
            throw ImpressCanvasError.tooLarge
        }
        artboard.frame = CGRect(x: 0, y: 0,
            width: CGFloat(max(320, width)), height: CGFloat(max(400, height)))
        artboard.backgroundColor = .systemBackground
        artboard.isAccessibilityElement = false
        addSubview(artboard)
        contentSize = artboard.bounds.size

        var frames: [String: CGRect] = [:]
        for node in all {
            frames[node.id] = CGRect(
                x: CGFloat(Double(node.x) - minX + 48),
                y: CGFloat(Double(node.y) - minY + 48),
                width: CGFloat(node.width), height: CGFloat(node.height))
        }
        for edge in source.edges {
            guard let from = frames[edge.fromNode], let to = frames[edge.toNode]
            else { continue }
            let start = Self.anchor(from, side: edge.fromSide ?? "right")
            let finish = Self.anchor(to, side: edge.toSide ?? "left")
            let path = UIBezierPath()
            path.move(to: start)
            let delta = max(20, abs(finish.x - start.x) * 0.38)
            path.addCurve(to: finish,
                controlPoint1: CGPoint(x: start.x + delta, y: start.y),
                controlPoint2: CGPoint(x: finish.x - delta, y: finish.y))
            if edge.toEnd == nil || edge.toEnd == "arrow" {
                let angle = atan2(finish.y - start.y, finish.x - start.x)
                let size: CGFloat = 9
                path.move(to: CGPoint(x: finish.x - cos(angle - .pi / 6) * size,
                                      y: finish.y - sin(angle - .pi / 6) * size))
                path.addLine(to: finish)
                path.addLine(to: CGPoint(x: finish.x - cos(angle + .pi / 6) * size,
                                        y: finish.y - sin(angle + .pi / 6) * size))
            }
            let line = CAShapeLayer()
            line.path = path.cgPath
            line.strokeColor = (Self.canvasColor(edge.color) ?? UIColor.secondaryLabel).cgColor
            line.fillColor = UIColor.clear.cgColor
            line.lineWidth = 1.6
            artboard.layer.addSublayer(line)
            if let label = edge.label, !label.isEmpty {
                let description = UILabel(frame: CGRect(
                    x: (start.x + finish.x) / 2 - 65,
                    y: (start.y + finish.y) / 2 - 10,
                    width: 130, height: 24))
                description.text = label
                description.font = .preferredFont(forTextStyle: .caption2)
                description.adjustsFontForContentSizeCategory = true
                description.textColor = .secondaryLabel
                description.textAlignment = .center
                description.backgroundColor = .systemBackground
                description.isUserInteractionEnabled = false
                artboard.addSubview(description)
            }
        }
        for node in all {
            guard let frame = frames[node.id] else { continue }
            let button = UIButton(type: .system)
            button.frame = frame
            button.backgroundColor = node.type == "group"
                ? UIColor.secondarySystemGroupedBackground.withAlphaComponent(0.55)
                : UIColor.secondarySystemGroupedBackground
            button.layer.cornerRadius = 10
            button.layer.borderWidth = node.type == "group" ? 2 : 1
            let originalColor = Self.canvasColor(node.color) ?? UIColor.separator
            originalNodeColors[node.id] = originalColor
            button.layer.borderColor = originalColor.cgColor
            button.clipsToBounds = true
            button.contentEdgeInsets = UIEdgeInsets(top: 9, left: 9, bottom: 9, right: 9)
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.contentHorizontalAlignment = .leading
            button.contentVerticalAlignment = .top
            let display = Self.displayText(for: node)
            if node.type == "text",
               let richText = MarkdownKitRenderer().parseMarkdown(display) {
                button.setAttributedTitle(richText, for: .normal)
            } else {
                button.setTitle(display, for: .normal)
                button.setTitleColor(.label, for: .normal)
            }
            button.accessibilityLabel = Self.displayText(for: node)
            button.isAccessibilityElement = true
            button.accessibilityTraits = .button
            button.accessibilityIdentifier = "impress.canvas.node." + node.id
            button.accessibilityHint = V3L("轻点选择或取消此节点；只有批准后才会加入 Chat")
            button.addAction(UIAction { [weak self] _ in
                self?.toggleSelection(node.id)
            }, for: .touchUpInside)
            artboard.addSubview(button)
            buttons[node.id] = button
        }
        artboard.accessibilityElements = source.nodes.compactMap { buttons[$0.id] }
    }

    required init?(coder: NSCoder) { fatalError("init(source:) unsupported") }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { artboard }

    private func toggleSelection(_ id: String) {
        if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
        for (key, button) in buttons {
            let selected = selectedIDs.contains(key)
            button.layer.borderColor = (selected
                ? ImpressV3Appearance.accent : (originalNodeColors[key] ?? UIColor.separator)).cgColor
            button.layer.borderWidth = selected ? 3 : 1
            button.accessibilityValue = selected ? V3L("已选择") : V3L("未选择")
        }
        onSelectionChanged?(selectedIDs)
    }

    /// Preset hues are intentionally app-defined in the JSON Canvas standard.
    /// Hex colors are honored when supplied; no remote style sheets are used.
    private static func canvasColor(_ token: String?) -> UIColor? {
        guard let token else { return nil }
        switch token {
        case "1": return .systemRed
        case "2": return .systemOrange
        case "3": return .systemYellow
        case "4": return .systemGreen
        case "5": return .systemTeal
        case "6": return .systemPurple
        default:
            guard token.first == "#", token.count == 7,
                  let value = Int(token.dropFirst(), radix: 16) else { return nil }
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }

    private static func anchor(_ rect: CGRect, side: String) -> CGPoint {
        switch side {
        case "left": return CGPoint(x: rect.minX, y: rect.midY)
        case "top": return CGPoint(x: rect.midX, y: rect.minY)
        case "bottom": return CGPoint(x: rect.midX, y: rect.maxY)
        default: return CGPoint(x: rect.maxX, y: rect.midY)
        }
    }

    private static func displayText(for node: ImpressCanvasNode) -> String {
        switch node.type {
        case "text": return node.text ?? V3L("空白文本")
        case "file":
            return (node.file ?? V3L("未找到文件路径")) +
                (node.subpath ?? "")
        case "link": return node.url ?? V3L("空白链接")
        case "group": return node.label ?? V3L("分组")
        default: return V3L("不支持的插件节点 · ") + node.type
        }
    }
}


// MARK: - V1.1 Mermaid and Markmap trusted offline renderer

/// WKWebView receives only inert source text and app-bundled JS/CSS. It is
/// never given a Vault URL/bookmark or arbitrary local file read access.
/// Explicit native selections are the authority for Chat material scope.
@MainActor
final class ImpressDiagramReaderController: UIViewController,
        UITableViewDataSource, UITableViewDelegate, WKNavigationDelegate, UISearchBarDelegate {
    private let source: ImVaultRawDocument
    private let diagram: ImpressDiagramDocument
    private let graph = WKWebView(frame: .zero, configuration: {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        return cfg
    }())
    private let choices = UITableView(frame: .zero, style: .plain)
    private let nodeSearch = UISearchBar()
    private var nodeQuery = ""
    private var visibleNodes: [ImpressDiagramNode] {
        guard !nodeQuery.isEmpty else { return diagram.nodes }
        return diagram.nodes.filter { $0.title.localizedCaseInsensitiveContains(nodeQuery) }
    }
    private let eventRelay = ImpressDiagramEventRelay()
    private let action = UIButton(type: .system)
    private let message = UILabel()
    private var chosen = Set<String>()
    private var ready = false
    private var allowedFolder: URL? {
        Bundle.main.url(forResource: "index", withExtension: "html",
            subdirectory: "DiagramReader")?.deletingLastPathComponent()
    }

    init(source: ImVaultRawDocument, diagram: ImpressDiagramDocument) {
        self.source = source
        self.diagram = diagram
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = diagram.kind == .mermaid ? "Mermaid" : "Markmap"
        view.backgroundColor = ImpressV3Appearance.page
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.accessibilityIdentifier = "impress.diagram.offline-graph"
        graph.navigationDelegate = self
        eventRelay.onState = { [weak self] state in
            guard let self else { return }
            if state == "ready" {
                self.message.text = V3L("本地图形已真实渲染。轻点下方节点选择发送范围。")
                self.message.accessibilityValue = "ready"
            } else {
                self.message.text = V3L("本地引擎渲染失败；不能以源码文本冒充图形。")
                self.message.accessibilityValue = "failed"
            }
        }
        graph.configuration.userContentController.add(eventRelay, name: "diagramState")
        graph.isOpaque = false
        graph.backgroundColor = ImpressV3Appearance.surface
        graph.allowsBackForwardNavigationGestures = false
        graph.scrollView.bounces = false
        choices.translatesAutoresizingMaskIntoConstraints = false
        choices.accessibilityIdentifier = "impress.diagram.source-selection"
        choices.dataSource = self
        choices.delegate = self
        choices.rowHeight = UITableView.automaticDimension
        choices.estimatedRowHeight = 54
        nodeSearch.frame = CGRect(x: 0, y: 0, width: 320, height: 48)
        nodeSearch.placeholder = V3L("查找标题或分支")
        nodeSearch.accessibilityIdentifier = "impress.diagram.node-search-bar"
        // UISearchBar is a container, not the SearchField used by XCUITest or
        // VoiceOver. Identify its actual editing control and keep it hittable.
        nodeSearch.searchTextField.accessibilityIdentifier = "impress.diagram.node-search"
        nodeSearch.searchTextField.accessibilityLabel = V3L("查找标题或分支")
        nodeSearch.delegate = self
        nodeSearch.searchBarStyle = .minimal
        nodeSearch.returnKeyType = .search
        choices.tableHeaderView = nodeSearch
        message.translatesAutoresizingMaskIntoConstraints = false
        message.accessibilityIdentifier = "impress.diagram.render-state"
        message.accessibilityValue = "loading"
        message.text = V3L("离线图形正在渲染。下方源节点选择不代表发送许可。")
        message.font = ImpressV3Appearance.Typography.footnote
        message.adjustsFontForContentSizeCategory = true
        message.textColor = ImpressV3Appearance.secondaryText
        message.numberOfLines = 0
        action.translatesAutoresizingMaskIntoConstraints = false
        ImpressV3Appearance.styleQuietButton(action,
            title: V3L("完整预览并加入 Chat"), symbol: "bubble.left")
        action.accessibilityIdentifier = "impress.diagram.preview-material"
        action.addTarget(self, action: #selector(previewMaterial), for: .touchUpInside)
        action.isEnabled = false
        view.addSubview(graph)
        view.addSubview(message)
        view.addSubview(choices)
        view.addSubview(action)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            graph.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            graph.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 8),
            graph.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -8),
            graph.heightAnchor.constraint(equalTo: safe.heightAnchor, multiplier: 0.52),
            message.topAnchor.constraint(equalTo: graph.bottomAnchor, constant: 6),
            message.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            message.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            choices.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 6),
            choices.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            choices.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            choices.bottomAnchor.constraint(equalTo: action.topAnchor, constant: -8),
            action.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            action.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            action.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -8),
            action.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
        guard let folder = allowedFolder else {
            message.text = V3L("离线图形引擎资源缺失。不可将源码列表冒充图形完成。")
            return
        }
        graph.loadFileURL(folder.appendingPathComponent("index.html"),
            allowingReadAccessTo: folder)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url,
              url.isFileURL, let allowedFolder,
              url.standardizedFileURL.deletingLastPathComponent() == allowedFolder.standardizedFileURL,
              url.lastPathComponent == "index.html" else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        render()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
        message.text = V3L("离线图形引擎加载失败：") + error.localizedDescription
    }
    private func render() {
        guard ready else { return }
        let payload: [String: Any] = [
            "kind": diagram.kind.rawValue,
            "source": diagram.rendererText,
            "dark": traitCollection.userInterfaceStyle == .dark
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let value = String(data: data, encoding: .utf8) else { return }
        graph.evaluateJavaScript("window.renderImpressDiagram(" + value + ");") {
            [weak self] _, error in
            if let error {
                self?.message.text = V3L("图形引擎不可用：") + error.localizedDescription
            }
        }
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            render()
        }
    }
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        nodeQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        choices.reloadData()
    }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        visibleNodes.count
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
        -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "diagram-node") ??
            UITableViewCell(style: .subtitle, reuseIdentifier: "diagram-node")
        let node = visibleNodes[indexPath.row]
        cell.textLabel?.text = node.title
        cell.textLabel?.numberOfLines = 2
        cell.textLabel?.font = ImpressV3Appearance.Typography.body
        cell.detailTextLabel?.text = "UTF8 " + String(node.startUTF8)
        cell.indentationLevel = min(6, diagram.kind == .markmap ? 1 : 0)
        cell.indentationWidth = 14
        cell.accessoryType = chosen.contains(node.id) ? .checkmark : .none
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = node.title
        cell.accessibilityIdentifier = "impress.diagram.node." + node.id
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let node = visibleNodes[indexPath.row]
        tableView.deselectRow(at: indexPath, animated: true)
        if chosen.contains(node.id) {
            chosen.remove(node.id)
            action.isEnabled = !chosen.isEmpty
            choices.reloadData()
            return
        }
        let hasChildren = diagram.nodes.contains { $0.parentID == node.id }
        guard hasChildren else {
            chosen.insert(node.id)
            action.isEnabled = true
            choices.reloadData()
            return
        }
        let prompt = UIAlertController(title: V3L("选择节点范围"),
            message: V3L("包含子树会将其子节点加入待审核材料；默认仅选当前节点。"),
            preferredStyle: .actionSheet)
        prompt.addAction(UIAlertAction(title: V3L("仅当前节点"), style: .default) {
            [weak self] _ in self?.completeSelection([node.id])
        })
        prompt.addAction(UIAlertAction(title: V3L("当前节点与子树"), style: .default) {
            [weak self] _ in
            guard let self, let selection = try? self.diagram.selection(
                ids: [node.id], includeDescendants: true) else { return }
            self.completeSelection(selection.ids)
        })
        prompt.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        prompt.popoverPresentationController?.sourceView = view
        present(prompt, animated: true)
    }
    private func completeSelection(_ ids: [String]) {
        chosen.formUnion(ids)
        action.isEnabled = !chosen.isEmpty
        choices.reloadData()
    }
    @objc private func previewMaterial() {
        guard !chosen.isEmpty,
              ImVaultReadOnlyProbe.shared.authorizedVaultID == source.identity.vaultID else {
            return
        }
        let expectedDigest = source.digest
        let requestedIDs = chosen
        ImVaultReadSync.shared.read(source.identity) { [weak self] result in
            guard let self else { return }
            do {
                let live = try result.get()
                guard live.identity == self.source.identity,
                      live.digest == expectedDigest,
                      ImVaultDigest.sha256(live.sourceBytes) == expectedDigest else {
                    throw ImVaultSyncFailure.conflict
                }
                let updated: ImpressDiagramDocument
                switch self.diagram.kind {
                case .mermaid:
                    let candidates = try ImpressDiagramDocument.mermaidBlocks(in: live.sourceBytes)
                    guard let match = candidates.first(where: {
                        $0.startUTF8 == self.diagram.startUTF8 &&
                        $0.endUTF8 == self.diagram.endUTF8
                    }) else { throw ImpressDiagramError.invalidSelection }
                    updated = match
                case .markmap:
                    updated = try ImpressDiagramDocument.markmap(in: live.sourceBytes)
                }
                guard updated.startUTF8 == self.diagram.startUTF8,
                      updated.endUTF8 == self.diagram.endUTF8 else {
                    throw ImVaultSyncFailure.conflict
                }
                let selection = try updated.selection(ids: requestedIDs)
                let json = try selection.contextJSON()
                let key = "note:" + (try ImpressBatchSourceKey.encode(live.identity))
                let reference = WCDBV3ChatContextReference(
                    stableIdentity: key, sourceRevision: live.digest,
                    excerpt: json, sourceStartUTF8: updated.startUTF8,
                    sourceEndUTF8: updated.endUTF8,
                    sourceFormat: updated.kind.rawValue + "-structure",
                    selectedCanvasNodeIDs: selection.ids)
                self.presentMaterialPreview(live, reference: reference, json: json)
            } catch {
                self.presentError(error)
            }
        }
    }

    private func presentMaterialPreview(_ live: ImVaultRawDocument,
                                        reference: WCDBV3ChatContextReference, json: String) {
        let page = UIViewController()
        page.view.backgroundColor = ImpressV3Appearance.page
        page.title = V3L("核对图形材料范围")
        let preview = UITextView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.isEditable = false
        preview.isSelectable = true
        preview.isScrollEnabled = true
        preview.font = ImpressV3Appearance.Typography.code
        preview.adjustsFontForContentSizeCategory = true
        preview.text = "Vault: " + live.identity.vaultID + "\n" +
            live.identity.relativePath + "\nSHA-256: " + live.digest +
            "\n" + V3L("此处仅是选中分支的文字与结构，不包含图像像素。") + "\n\n" + json
        preview.accessibilityIdentifier = "impress.diagram.material-preview"
        page.view.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.topAnchor),
            preview.bottomAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.trailingAnchor)
        ])
        page.navigationItem.rightBarButtonItem = UIBarButtonItem(primaryAction: UIAction(
            title: V3L("确认范围并加入 Chat"), image: UIImage(systemName: "bubble.left")) {
                [weak self] _ in
            guard let self, ImVaultReadOnlyProbe.shared.authorizedVaultID ==
                live.identity.vaultID else { return }
            do {
                let repo = try ImpressV3ReviewEnvironment.repository()
                let chat = ImpressAINativeChatViewController(
                    question: V3L("来源图形：") + live.identity.relativePath,
                    answer: nil, repository: repo, sourceKey: reference.stableIdentity,
                    sourceVersion: live.digest, noteIdentity: live.identity,
                    initialMaterials: [reference])
                self.navigationController?.pushViewController(chat, animated: true)
            } catch { self.presentError(error) }
        })
        page.navigationItem.rightBarButtonItem?.accessibilityIdentifier =
            "impress.diagram.confirm-material"
        navigationController?.pushViewController(page, animated: true)
    }
    private func presentError(_ error: Error) {
        let alert = UIAlertController(title: V3L("图形来源核查失败"),
            message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        present(alert, animated: true)
    }
}



/// WKWebView owns the relay, but the relay never owns the reader. No
/// persistent web storage or Vault capability is exposed across this bridge.
final class ImpressDiagramEventRelay: NSObject, WKScriptMessageHandler {
    var onState: ((String) -> Void)?
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "diagramState",
              let body = message.body as? [String: String],
              let state = body["state"],
              state == "ready" || state == "failed" else { return }
        DispatchQueue.main.async { [weak self] in self?.onState?(state) }
    }
}


// MARK: - G3 offline semantic Markdown body

/// One local, non-persistent WebKit reading surface; Vault markdown is only
/// a string argument to a bundled markdown-it engine, never executable JS,
/// never a file URL, and never an authority for source edits or Chat consent.
@MainActor
final class ImpressMarkdownOfflineView: UIView, WKNavigationDelegate {
    var onTouchLink: ((URLRequest) -> Bool)?
    var isScrollEnabled: Bool {
        get { web.scrollView.isScrollEnabled }
        set { web.scrollView.isScrollEnabled = newValue }
    }
    private var sourceMarkdown = ""
    private var activeCSS = ""
    private var activeTitle = ""
    private var allowImages = false
    private var projectedFields: [[String: String]] = []
    private var propertiesDiagnostic = ""
    private var propertiesState = "absent"
    private var activeSourceDigest = ""
    private var isLoaded = false
    private var requestedVersion: Int = 0
    private let relay = ImpressMarkdownStateRelay()
    private let web: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        return WKWebView(frame: .zero, configuration: config)
    }()
    private var allowedFolder: URL? {
        Bundle.main.url(forResource: "index", withExtension: "html",
            subdirectory: "MarkdownReader")?.deletingLastPathComponent()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        web.translatesAutoresizingMaskIntoConstraints = false
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = false
        web.isOpaque = false
        web.backgroundColor = ImpressV3Appearance.surface
        web.scrollView.backgroundColor = ImpressV3Appearance.surface
        web.scrollView.accessibilityIdentifier = "impress.notes.continuous-scroll"
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.accessibilityIdentifier = "impress.notes.markdown-webview"
        web.accessibilityValue = "loading"
        web.configuration.userContentController.add(relay, name: "markdownState")
        relay.onState = { [weak self] report in
            self?.web.accessibilityValue = report
        }
        addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: leadingAnchor),
            web.trailingAnchor.constraint(equalTo: trailingAnchor),
            web.topAnchor.constraint(equalTo: topAnchor),
            web.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        guard let folder = allowedFolder else {
            web.accessibilityValue = "asset-missing"
            return
        }
        web.loadFileURL(folder.appendingPathComponent("index.html"),
                        allowingReadAccessTo: folder)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func load(markdown: String, enableImage: Bool, css: String,
              documentTitle: String, properties: ImpressFrontmatterReading,
              sourceDigest: String) {
        // Only a bounded, typed, inert display projection enters WebKit.
        // Never pass raw YAML, Vault paths, file handles or edit authority.
        let fields: [[String: String]] = properties.fields.prefix(128).map {
            ["name": $0.name, "kind": $0.kind.rawValue,
             "value": $0.displayValue]
        }
        let diagnostic = properties.diagnostic ?? ""
        let state = properties.state.rawValue
        guard markdown != sourceMarkdown || css != activeCSS ||
              documentTitle != activeTitle || fields != projectedFields ||
              diagnostic != propertiesDiagnostic || state != propertiesState ||
              sourceDigest != activeSourceDigest ||
              enableImage != allowImages || requestedVersion == 0 else { return }
        sourceMarkdown = markdown
        activeCSS = css
        activeTitle = documentTitle
        web.accessibilityLabel = documentTitle
        projectedFields = fields
        propertiesDiagnostic = diagnostic
        propertiesState = state
        activeSourceDigest = sourceDigest
        allowImages = enableImage
        requestedVersion += 1
        render()
    }

    private func render() {
        guard isLoaded else { return }
        let request = requestedVersion
        let markdown = sourceMarkdown
        let imagePolicy = allowImages
        let options: [String: Any] = [
            "css": activeCSS,
            "documentTitle": activeTitle,
            "dark": traitCollection.userInterfaceStyle == .dark,
            "fontSize": UIFont.preferredFont(forTextStyle: .body).pointSize,
            "allowImages": imagePolicy,
            "properties": projectedFields,
            "propertiesDiagnostic": propertiesDiagnostic,
            "propertiesState": propertiesState,
            "documentKey": activeSourceDigest
        ]
        web.accessibilityValue = "loading"
        web.callAsyncJavaScript(
            "return await window.renderImpressMarkdown(markdown, options);",
            arguments: ["markdown": markdown, "options": options],
            in: nil, in: .page
        ) { [weak self] result in
            guard let self, self.requestedVersion == request else { return }
            if case .failure = result { self.web.accessibilityValue = "failed" }
        }
    }
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle ||
           previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            requestedVersion += 1
            render()
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        render()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
        web.accessibilityValue = "failed"
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else {
            decisionHandler(.cancel)
            return
        }
        if action.navigationType == .linkActivated, url.scheme == "https",
           url.host == "impress.invalid", url.path == "/wiki" {
            _ = onTouchLink?(action.request)
            decisionHandler(.cancel)
            return
        }
        guard let folder = allowedFolder, url.isFileURL,
              url.standardizedFileURL == folder.appendingPathComponent("index.html")
                  .standardizedFileURL else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

/// Only a bounded render status is reported across the JavaScript bridge.
/// It has no way to request source bytes, Vault URLs, SQL, or Chat actions.
private final class ImpressMarkdownStateRelay: NSObject, WKScriptMessageHandler {
    var onState: ((String) -> Void)?
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "markdownState",
              let payload = message.body as? [String: Any],
              let state = payload["state"] as? String,
              ["ready", "partial", "failed"].contains(state),
              let total = payload["diagramCount"] as? Int, (0...24).contains(total),
              let rendered = payload["rendered"] as? Int, (0...24).contains(rendered),
              let failed = payload["failures"] as? Int, (0...24).contains(failed),
              let maths = payload["mathCount"] as? Int, (0...512).contains(maths),
              rendered <= total, failed <= max(1, total) else { return }
        let evidence = state + ":g=" + String(rendered) + "/" + String(total) +
            ":m=" + String(maths)
        DispatchQueue.main.async { [weak self] in self?.onState?(evidence) }
    }
}


// MARK: - Full-document on-device Chinese translation (iOS 26+)
private struct ImpressNoteChineseTranslationReader: View {
    let sourceTitle: String
    let original: String
    @State private var showsOriginal = false
    @State private var translated: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker(V3L("阅读版本"), selection: $showsOriginal) {
                Text(V3L("中文译文")).tag(false)
                Text(V3L("原文")).tag(true)
            }
            .pickerStyle(.segmented)
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(sourceTitle).font(.headline)
                    if showsOriginal {
                        Text(original).textSelection(.enabled)
                    } else if let translated {
                        Text(translated).textSelection(.enabled)
                    } else if let errorMessage {
                        Text(errorMessage).foregroundStyle(.secondary)
                        Text(V3L("可切换至原文继续阅读。"))
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView(V3L("正在设备端翻译全文…"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
        .translationTask(source: nil,
                         target: Locale.Language(identifier: "zh-Hans")) { session in
            guard !original.isEmpty else {
                await MainActor.run { translated = "" }
                return
            }
            var output = ""
            do {
                // Split long notes to avoid provider request-size failures,
                // preserving the original order and newline boundaries.
                for chunk in Self.translationChunks(original) {
                    if Task.isCancelled { return }
                    let response = try await session.translate(chunk)
                    output += response.targetText
                }
                await MainActor.run { translated = output }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    private static func translationChunks(_ source: String) -> [String] {
        var chunks: [String] = []
        var chunk = ""
        var count = 0
        for character in source {
            chunk.append(character)
            count += 1
            if count >= 1_200 && (character == "\n" || count >= 1_600) {
                chunks.append(chunk)
                chunk = ""
                count = 0
            }
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }
}
