//
//  ImSubmitViewController.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 5/13/25.
//

import UIKit
import PhotosUI
import UniformTypeIdentifiers
import ImageIO

class ImSubmitViewController<T: ImSubmitConfigureProtocol>: ImBaseViewController, UITableViewDataSource, UITableViewDelegate, PHPickerViewControllerDelegate, ImSubmitCellDelegate
{
    // 使用简化的自定义导航栏，跟随系统默认样式
    private lazy var customNavigationBar: UINavigationBar = {
        let navBar = UINavigationBar()
        navBar.translatesAutoresizingMaskIntoConstraints = false
        navBar.prefersLargeTitles = false
        navBar.isTranslucent = false
        return navBar
    }()

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    
    private let reuseID = String(describing: ImSubmitCell.self)
    
    /// 显示的cell类型数组
    private var sections:[[ImSubmitCellType]] = []
    
    ///
    private var submitModel: T!
    
    var isEditMode: Bool = false

    /// 控制是否在类型改变时清空模型数据，避免初始化时意外清空
    private var shouldClearModelOnTypeChange = true
    private var isImageProcessing = false

    private var selectedCardType: CardType = .standard {
        didSet {
            if oldValue != selectedCardType && shouldClearModelOnTypeChange {
                // 只在用户主动改变类型时清空数据，避免初始化时清空现有数据
                if var cardModel = submitModel as? ImCardModel {
                    cardModel.submitQuestion = nil
                    cardModel.submitAnswer = nil
                    cardModel.imageData = nil
                    self.submitModel = cardModel as? T
                }
            }
            updateSections(for: selectedCardType)
        }
    }
    
    /// 模型回调对象
    var submitActionResult:((T) ->Void)?

    /// 是否为草稿模式
    var isDraftMode: Bool = false







    
    // MARK: - Init Function
    /// - Parameter submitModel: 遵守submitConfigureProtocol协议的实例对象
    init(submitModel:T)
    {
        super.init(nibName: nil, bundle: nil)
        self.submitModel = submitModel
        self.isModalInPresentation = true
    }
    
    required public init?(coder: NSCoder)
    {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad()
    {
        super.viewDidLoad()

        // 初始化卡片类型，避免触发数据清空
        shouldClearModelOnTypeChange = false
        if let cardModel = submitModel as? ImCardModel, let typeRaw = cardModel.cardType, let type = CardType(rawValue: typeRaw) {
            selectedCardType = type
        } else {
            selectedCardType = .standard
        }
        shouldClearModelOnTypeChange = true

        // 设置UI组件
        initTableviewSetting()
        itemsSetting()
        setupConstraints()

        // 添加手势支持，点击空白区域收起键盘
        setupTapGestureToDismissKeyboard()
    }

    private func setupTapGestureToDismissKeyboard() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tapGesture.cancelsTouchesInView = false
        view.addGestureRecognizer(tapGesture)
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }
    
    private func updateSections(for type: CardType) {
        if isDraftMode {
            sections = [[.inputTitle], [.input]]
        } else {
            sections = [
                [.selectCardType]
            ]

            switch type {
            case .standard:
                sections.append([.inputTitle])
                sections.append([.input])
            case .multipleChoice:
                sections.append([.input]) // Only one input field for Q&A format
            case .image:
                sections.append([.inputTitle])
                sections.append([.imagePicker])
            }

            // 提交按钮移至导航栏，不再需要添加submit section
        }
        tableView.reloadData()
    }
    
    private func itemsSetting()
    {
        view.addSubview(customNavigationBar)

        // 配置导航项
        let navItem = UINavigationItem()
        navItem.title = submitModel.submitType.itemTitle

        // 左边关闭按钮
        let leftItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark.circle.fill")?.withConfiguration(
                UIImage.SymbolConfiguration(weight: .semibold)
            ),
            style: .plain,
            target: self,
            action: #selector(exitSubmitController)
        )
        navItem.leftBarButtonItem = leftItem

        // 右边提交按钮
        let rightItem = UIBarButtonItem(
            title: "提交",
            style: .done,
            target: self,
            action: #selector(handleSubmitButtonPressed)
        )
        navItem.rightBarButtonItem = rightItem

        customNavigationBar.setItems([navItem], animated: false)

        // 使用系统默认外观，不进行额外定制
        if #available(iOS 13.0, *) {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithDefaultBackground()  // 使用系统默认背景
            customNavigationBar.standardAppearance = appearance
            customNavigationBar.scrollEdgeAppearance = appearance
        }
    }
    
    private func setupConstraints()
    {
        let guide = view.safeAreaLayoutGuide

        // 导航栏约束
        NSLayoutConstraint.activate([
            customNavigationBar.topAnchor.constraint(equalTo: guide.topAnchor),
            customNavigationBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            customNavigationBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            customNavigationBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 44.0)
        ])

        // 表格视图约束 - 在导航栏下方
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: customNavigationBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
        ])
    }
    
    @objc func exitSubmitController()
    {
        dismiss(animated: true, completion: nil)
    }

    @objc func handleSubmitButtonPressed()
    {
        handlerSubmitResult()
    }
    
    
    // MARK: - TableView业务逻辑 + UITableViewDelegate
    func initTableviewSetting()
    {
        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(ImSubmitCell.self,
                           forCellReuseIdentifier: reuseID)

        // 应用现代表格视图外观
        setupTableViewAppearance()

        tableView.delegate = self
        tableView.dataSource = self
        tableView.showsVerticalScrollIndicator = false
        tableView.tableFooterView = UIView(frame: .zero)

        // 添加键盘处理通知
        setupKeyboardHandling()
    }

    private func setupTableViewAppearance() {
        if #available(iOS 13.0, *) {
            // 配置背景色和样式
            tableView.backgroundColor = bgColor

            // 现代分割线样式
            tableView.separatorStyle = .singleLine
            tableView.separatorColor = separatorColor
            tableView.separatorInset = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)

            // 优化滚动体验
            tableView.estimatedRowHeight = 60
            tableView.rowHeight = UITableView.automaticDimension

            // 增强视觉效果
            tableView.layer.cornerRadius = 12
            tableView.layer.masksToBounds = true

            // 添加轻微阴影
            tableView.layer.shadowColor = shadowColor.cgColor
            tableView.layer.shadowOffset = CGSize(width: 0, height: 2)
            tableView.layer.shadowRadius = 8
            tableView.layer.shadowOpacity = 0.1
        }
    }

    private func setupKeyboardHandling() {
        // 添加键盘显示/隐藏通知观察者
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval else {
            return
        }

        // 计算键盘高度并调整表格视图底部内边距
        let keyboardHeight = keyboardFrame.height
        let contentInsets = UIEdgeInsets(top: 0, left: 0, bottom: keyboardHeight, right: 0)

        UIView.animate(withDuration: duration) {
            self.tableView.contentInset = contentInsets
            self.tableView.scrollIndicatorInsets = contentInsets
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval else {
            return
        }

        // 恢复原始内边距
        let contentInsets = UIEdgeInsets.zero

        UIView.animate(withDuration: duration) {
            self.tableView.contentInset = contentInsets
            self.tableView.scrollIndicatorInsets = contentInsets
        }
    }
    
    func numberOfSections(in tableView: UITableView) -> Int
    {
        return sections.count
    }
    
    func tableView(_ tableView: UITableView,
                   numberOfRowsInSection section: Int) -> Int
    {
        return sections[section].count
    }
    
    func tableView(_ tableView: UITableView,
                   heightForRowAt indexPath: IndexPath) -> CGFloat
    {
        let type = sections[indexPath.section][indexPath.row]
        if selectedCardType == .multipleChoice && type == .input {
            // fix 话术最优视觉呈现
            return defaultSpacing * 10
        }
        return UITableView.automaticDimension
    }
    
    func tableView(_ tableView: UITableView,
                   titleForHeaderInSection section: Int) -> String?
    {
        var title: String? = nil
        let type = sections[section]
        switch type.first! {
        case .input:
            if selectedCardType == .multipleChoice {
                title = "问题和选项"
            } else {
                title = submitModel.submitType.sectionTitle.last!
            }
            break
        case .inputTitle:
            title = submitModel.submitType.sectionTitle.first!
            break
        default:break
        }
        return title
    }
    
    func tableView(_ tableView: UITableView,
                   cellForRowAt indexPath: IndexPath) -> UITableViewCell
    {
        let cell = tableView.dequeueReusableCell(withIdentifier: reuseID,
                                                 for: indexPath) as! ImSubmitCell
        let type = sections[indexPath.section][indexPath.row]

        cell.updateConfig(cellType: type, model: submitModel,
                          cardType: selectedCardType, isEditMode: isEditMode)

        cell.delegate = self

        // Use closures for event handling
        cell.onCardTypeChanged = { [weak self] selectedIndex in
            self?.selectedCardType = CardType.allCases[selectedIndex]
        }

        cell.onPickImageTapped = { [weak self] in
            self?.pickImage()
        }

        return cell
    }
    
    @objc private func pickImage() {
        guard !isImageProcessing else { return }
        // PHPicker shows only the assets explicitly selected by the user,
        // with no blanket NSPhotoLibraryUsageDescription permission prompt.
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        // User cancelling is not an error and must not clear existing image.
        guard let item = results.first?.itemProvider else { return }
        guard item.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            ImAlertController.warningAlert("相册项目不是可读取的图片。")
            return
        }
        isImageProcessing = true
        // Providers generally vend concrete public.jpeg/public.heic, not
        // necessarily public.image itself. Ask for the registered image UTI.
        let fileType = item.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) ?? UTType.image.identifier
        let kind: ImpressImageOptimizer.ContentKind =
            UTType(fileType)?.conforms(to: .png) == true ? .document : .photo
        // File representation + ImageIO thumbnail avoids decoding a 48MP
        // iCloud photo into full-resolution UIImage memory before compression.
        // ItemProvider deletes its temporary file when this callback returns,
        // so thumbnail generation must happen INSIDE this callback.
        item.loadFileRepresentation(forTypeIdentifier: fileType) { [weak self] fileURL, providerError in
            guard let fileURL = fileURL,
                  let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
                DispatchQueue.main.async {
                    self?.isImageProcessing = false
                    ImAlertController.warningAlert(providerError?.localizedDescription ??
                        "图片读取失败；请检查 iCloud 下载状态。")
                }
                return
            }
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: kind == .document ? 2000 : 1280
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                src, 0, thumbnailOptions as CFDictionary) else {
                DispatchQueue.main.async {
                    self?.isImageProcessing = false
                    ImAlertController.warningAlert("图片缩略解码失败，原相册照片未被修改。")
                }
                return
            }
            let source = UIImage(cgImage: cgImage)
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try ImpressImageOptimizer.optimize(source, kind: kind) }
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isImageProcessing = false
                    guard self.selectedCardType == .image else { return }
                    switch result {
                    case let .success(data):
                        if var model = self.submitModel as? ImCardModel {
                            model.imageData = data
                            self.submitModel = model as? T
                            self.tableView.reloadData()
                        }
                    case let .failure(error):
                        ImAlertController.warningAlert("图片压缩失败：\(error.localizedDescription)")
                    }
                }
            }
        }
    }

    
    func tableView(_ tableView: UITableView,
                   didSelectRowAt indexPath: IndexPath)
    {
        tableView.deselectRow(at: indexPath,
                              animated: true)
        let type = sections[indexPath.section][indexPath.row]

        // 点击输入框时隐藏键盘
        if type.isInput {
            let cell = tableView.dequeueReusableCell(withIdentifier: reuseID,
                                                     for: indexPath) as! ImSubmitCell
            cell.shareTextView.resignFirstResponder()
        }
    }
    
    /// 处理提交事件的模型返回
    private func handlerSubmitResult()
    {
        guard !isImageProcessing else {
            ImAlertController.warningAlert("图片仍在读取及压缩，请完成后再保存。")
            return
        }
        // --- 1. Get common fields ---
        var titleText: String?
        if let titleSection = sections.firstIndex(where: { $0.contains(.inputTitle) }),
           let titleCell = tableView.cellForRow(at: IndexPath(row: 0, section: titleSection)) as? ImSubmitCell {
            titleText = titleCell.shareTextView.text
        }
        
        var contentText: String?
        if let contentSection = sections.firstIndex(where: { $0.contains(.input) }),
           let contentCell = tableView.cellForRow(at: IndexPath(row: 0, section: contentSection)) as? ImSubmitCell {
            contentText = contentCell.shareTextView.text
        }

        if selectedCardType != .multipleChoice &&
           (titleText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            ImAlertController.warningAlert("卡片的问题不能为空。")
            return
        }
        
        if selectedCardType != .image && (contentText == nil || contentText!.isEmpty) {
            ImAlertController.warningAlert("内容不能为空。")
            return
        }
        
        // --- 2. Update the model based on the selected card type ---
        if var cardModel = submitModel as? ImCardModel {
            cardModel.cardType = selectedCardType.rawValue
            
            // --- Intelligent Parsing for Multiple Choice ---
            if selectedCardType == .multipleChoice {
                guard let content = contentText, !content.isEmpty else {
                    ImAlertController.warningAlert("内容不能为空。")
                    return
                }

                let parseResult = parseQnAFormat(text: content)

                switch parseResult {
                case .success(let parsedQuestions):
                    for questionData in parsedQuestions {
                        var newCardModel = ImCardModel()
                        newCardModel.cardType = selectedCardType.rawValue
                        newCardModel.createTime = Date()
                        newCardModel.noteID = self.submitModel.submitNoteID
                        newCardModel.question = questionData.question
                        newCardModel.choices = questionData.options.joined(separator: "\n")
                        let correctIndicesArray = questionData.correctIndices.map { String($0) }
                        newCardModel.correctAnswerIndices = correctIndicesArray.joined(separator: ",")
                        
                        // Set the 'answer' field to the text of the correct options for display purposes.
                        if let indices = newCardModel.correctAnswerIndices, !indices.isEmpty {
                            let correctOptions = indices.split(separator: ",").compactMap { Int($0) }.filter { $0 < questionData.options.count }.map { questionData.options[$0] }
                            newCardModel.submitAnswer = correctOptions.joined(separator: ", ")
                        }
                        
                        submitActionResult?(newCardModel as! T)
                    }
                    exitSubmitController()
                    return // Do not insert an additional empty choice card.
                case .failure(let error):
                    ImAlertController.warningAlert(error.localizedDescription)
                    return
                }
            } else {
                // 根据卡片类型正确保存数据
                cardModel.submitQuestion = titleText
                if selectedCardType == .standard {
                    cardModel.submitAnswer = contentText
                }
                // 图片类型的 answer 字段保持为空（因为没有内容输入框）
            }
            // --- Handle other card types ---
            switch selectedCardType {
            case .image:
                // imageData is already set by the image picker delegate
                if cardModel.imageData == nil {
                    ImAlertController.warningAlert("请选择一张图片。")
                    return
                }
            default:
                break
            }
            
            submitActionResult?(cardModel as! T)
            exitSubmitController()

        } else {
            // Handle other types that conform to ImSubmitConfigureProtocol if necessary
            submitModel.submitQuestion = titleText
            submitModel.submitAnswer = contentText
            submitActionResult?(submitModel)
            exitSubmitController()
        }
    }

    // MARK: - Q&A Format Parser

    struct ParsedQuestion {
        let question: String
        let options: [String]
        let correctIndices: [Int]
        let isMultipleChoice: Bool
    }

    /// Parses text in Q&A format, supporting single-choice, multiple-choice, and batch questions.
    /// - Parameter text: The full text input by the user.
    /// - Returns: An array of parsed questions or an error.
    private func parseQnAFormat(text: String) -> Result<[ParsedQuestion], Error> {
        var questions: [ParsedQuestion] = []
        
        let questionBlocks = text.components(separatedBy: "#").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        guard !questionBlocks.isEmpty else {
            return .failure(NSError(domain: "ParsingError", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到任何题目，请使用 '#' 开始一道新题。"]))
        }
        
        for block in questionBlocks {
            var lines = block.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            
            guard let questionText = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines), !questionText.isEmpty else { continue }
            lines.removeFirst()
            
            var options: [String] = []
            var correctIndices: [Int] = []
            var optionIndex = 0
            
            for line in lines {
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedLine.isEmpty { continue }
                
                if trimmedLine.starts(with: "*") {
                    let optionText = String(trimmedLine.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                    options.append(optionText)
                    correctIndices.append(optionIndex)
                    optionIndex += 1
                } else if trimmedLine.starts(with: "-") {
                    let optionText = String(trimmedLine.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                    options.append(optionText)
                    optionIndex += 1
                }
            }
            
            if options.isEmpty {
                return .failure(NSError(domain: "ParsingError", code: 2, userInfo: [NSLocalizedDescriptionKey: "题目 '\(questionText)' 缺少选项。"]))
            }
            if correctIndices.isEmpty {
                return .failure(NSError(domain: "ParsingError", code: 3, userInfo: [NSLocalizedDescriptionKey: "题目 '\(questionText)' 未指定正确答案，请使用 '*' 标记。"]))
            }
            
            let isMultiple = correctIndices.count > 1
            let parsedQuestion = ParsedQuestion(question: questionText, options: options, correctIndices: correctIndices, isMultipleChoice: isMultiple)
            questions.append(parsedQuestion)
        }
        
        return .success(questions)
    }
    
    // MARK: - ImSubmitCellDelegate
    func textViewDidChange(cell: ImSubmitCell) {
        // Update the layout of the table view
        UIView.setAnimationsEnabled(false)
        tableView.beginUpdates()
        tableView.endUpdates()
        UIView.setAnimationsEnabled(true)

        // Also update the model
        if let indexPath = tableView.indexPath(for: cell) {
            let type = sections[indexPath.section][indexPath.row]
            if var cardModel = submitModel as? ImCardModel {
                if type == .inputTitle {
                    cardModel.submitQuestion = cell.shareTextView.text
                } else if type == .input {
                    cardModel.submitAnswer = cell.shareTextView.text
                }
                self.submitModel = cardModel as? T
            }
        }
    }

    // MARK: - Memory Management
    deinit {
        // 移除键盘通知观察者，避免内存泄漏
        NotificationCenter.default.removeObserver(self)
    }
}
