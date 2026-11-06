import UIKit
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import ImpressReviewCore

// R04.2: V3 owns its editor, rather than mutating the legacy generic
// ImSubmitViewController used by chat drafts and older card workflows.
// Switching the selected type never destroys question/answer/image drafts.
/// Legacy choice answerText stored only the labels of correct options.
/// correctIndices remains authoritative; this reversible suffix stores optional
/// explanation without rewriting existing WCDB records.
enum ImpressV3ChoiceExplanation {
    static let separator = "\n\n解析：\n"
    static func encode(correctLabels: String, explanation: String) -> String {
        let edited = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        return edited.isEmpty ? correctLabels : correctLabels + separator + edited
    }
    static func decode(_ stored: String, correctLabels: String) -> String {
        if stored == correctLabels { return "" }
        let prefix = correctLabels + separator
        if stored.hasPrefix(prefix) { return String(stored.dropFirst(prefix.count)) }
        return stored // Preserve unknown legacy/imported content without data loss.
    }
}

struct ImpressV3CardDraft {
    struct Choice: Equatable {
        let id: UUID
        var text: String
        var isCorrect: Bool

        init(id: UUID = UUID(), text: String = "", isCorrect: Bool = false) {
            self.id = id
            self.text = text
            self.isCorrect = isCorrect
        }
    }

    var kind: CardType = .standard
    var question: String = ""
    var answer: String = ""
    var choices: [Choice] = [Choice(), Choice()]
    var allowsMultipleCorrect = false
    var imageData: Data?
    var sourceNotePath: String?

    func validatedInput(cardID: UUID = UUID()) throws -> WCDBV3CardInput {
        let prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw ValidationError.missingQuestion }
        switch kind {
        case .standard:
            let response = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !response.isEmpty else { throw ValidationError.missingAnswer }
            return WCDBV3CardInput(cardID: cardID, question: prompt,
                                  answerText: response, cardType: CardType.standard.rawValue,
                                  sourceNotePath: sourceNotePath)
        case .multipleChoice:
            guard (2...12).contains(choices.count) else { throw ValidationError.optionCount }
            let labels = choices.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !labels.contains(where: { $0.isEmpty || $0.contains("\n") || $0.contains("\r") })
            else { throw ValidationError.emptyOption }
            guard Set(labels.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                             locale: .current) }).count == labels.count
            else { throw ValidationError.duplicateOption }
            let correct = choices.enumerated().compactMap { $0.element.isCorrect ? $0.offset : nil }
            guard !correct.isEmpty else { throw ValidationError.missingCorrect }
            guard allowsMultipleCorrect || correct.count == 1
            else { throw ValidationError.singleCorrectOnly }
            return WCDBV3CardInput(cardID: cardID, question: prompt,
                                  answerText: ImpressV3ChoiceExplanation.encode(
                                       correctLabels: correct.map { labels[$0] }.joined(separator: "、"),
                                       explanation: answer),
                                  choices: labels.joined(separator: "\n"),
                                  correctIndices: correct.map(String.init).joined(separator: ","),
                                  cardType: CardType.multipleChoice.rawValue,
                                  sourceNotePath: sourceNotePath)
        case .image:
            guard let data = imageData, !data.isEmpty else {
                throw ValidationError.missingImage
            }
            return WCDBV3CardInput(cardID: cardID, question: prompt, cardType: CardType.image.rawValue,
                                  imageData: data, sourceNotePath: sourceNotePath)
        }
    }

    enum ValidationError: LocalizedError {
        case missingQuestion, missingAnswer, optionCount, emptyOption
        case duplicateOption, missingCorrect, singleCorrectOnly, missingImage
        var errorDescription: String? {
            switch self {
            case .missingQuestion: return V3L("请填写卡片的问题。")
            case .missingAnswer: return V3L("问答卡片需要一个答案。")
            case .optionCount: return V3L("选择题需要 2 到 12 个选项。")
            case .emptyOption: return V3L("请填写全部选项；单个选项不能包含换行。")
            case .duplicateOption: return V3L("选择题的选项不能重复。")
            case .missingCorrect: return V3L("请直接点选至少一个正确答案。")
            case .singleCorrectOnly: return V3L("单选模式只能标记一个正确答案；也可以切换到多选。")
            case .missingImage: return V3L("请选择并完成压缩一张图片。")
            }
        }
    }
}

@MainActor
final class ImpressV3CardComposerViewController: UIViewController,
    PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    var onSave: ((WCDBV3CardInput) async throws -> Void)?
    /// Set by the data/backup integration owner only after media CAS is implemented.
    var onSaveVideo: ((WCDBV3CardInput, ImpressCardVideoAVFoundationExporter.Staged) async throws -> Void)?
    /// Explicitly removes only the current media reference using WCDB content CAS.
    /// The cover stays an ordinary image; immutable history remains recoverable.
    var onRemoveVideo: ((WCDBV3CardInput) async throws -> Void)?

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let typePicker = UISegmentedControl(items: [V3L("问答"), V3L("选择题"), V3L("图片")])
    private let questionView = UITextView()
    private let answerView = UITextView()
    private var standardAnswerDraft: String
    private var choiceExplanationDraft: String
    private var answerTitleLabel: UILabel?
    private let qaSection = UIStackView()
    private let choiceSection = UIStackView()
    private let photoSection = UIStackView()
    private let choiceMode = UISegmentedControl(items: [V3L("单选"), V3L("多选")])
    private let optionList = UIStackView()
    private let addOptionButton = UIButton(type: .system)
    private let imageButton = UIButton(type: .system)
    private let videoCaptureButton = UIButton(type: .system)
    private var capturedVideoSource: URL?
    private var activeVideoImportToken = UUID()
    private let imagePreview = UIImageView()
    private let cancelVideoButton = UIButton(type: .system)
    private let removeExistingVideoButton = UIButton(type: .system)
    private let editingHasVideo: Bool
    private var removeExistingVideoPending = false
    private let videoImporter = ImpressCardVideoImportCoordinator()
    private var stagedVideo: ImpressCardVideoAVFoundationExporter.Staged?
    private var imageRequestID = UUID()
    private let createdCardID = UUID()
    private let expectedEditingContentRevision: Int?
    private var photoStatus = UILabel()
    private var choiceDrafts: [ImpressV3CardDraft.Choice]
    private var imageData: Data?
    private var processingPhoto = false
    private var saving = false
    private var originalDraft: ImpressV3CardDraft
    private var currentType: CardType
    private var saveItem: UIBarButtonItem?
    var onOpenContentHistory: (() -> Void)?
    private let editingCardID: UUID?

    init(draft: ImpressV3CardDraft = ImpressV3CardDraft(),
         editingCardID: UUID? = nil, expectedContentRevision: Int? = nil,
         editingHasVideo: Bool = false) {
        self.editingCardID = editingCardID
        self.expectedEditingContentRevision = expectedContentRevision
        self.editingHasVideo = editingCardID != nil && editingHasVideo
        self.originalDraft = draft
        self.currentType = draft.kind
        self.standardAnswerDraft = draft.kind == .standard ? draft.answer : ""
        let correctLabels = draft.choices.filter { $0.isCorrect }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "、")
        self.choiceExplanationDraft = draft.kind == .multipleChoice
            ? ImpressV3ChoiceExplanation.decode(draft.answer, correctLabels: correctLabels)
            : ""
        self.choiceDrafts = draft.choices
        self.imageData = draft.imageData
        super.init(nibName: nil, bundle: nil)
        isModalInPresentation = true
    }

    required init?(coder: NSCoder) { fatalError("init(draft:) required") }

    @objc private func openCardContentHistory() {
        guard !saving else { return }
        onOpenContentHistory?()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = editingCardID == nil ? V3L("新增卡片") : V3L("编辑卡片")
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = ImpressV3Appearance.page
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.leftBarButtonItem?.tintColor = ImpressV3Appearance.navigationActionInk
        // Match the other system navigation actions (not a custom filled save pill).
        let save = UIBarButtonItem(image: UIImage(systemName: "checkmark"), style: .plain,
                                   target: self, action: #selector(saveCard))
        save.accessibilityLabel = V3L("保存")
        save.accessibilityIdentifier = "impress.composer.save"
        save.tintColor = ImpressV3Appearance.navigationActionInk
        navigationItem.rightBarButtonItem = save
        saveItem = save
        if editingCardID != nil && onOpenContentHistory != nil {
            let history = UIBarButtonItem(image: UIImage(systemName: "clock.arrow.circlepath"),
                style: .plain, target: self, action: #selector(openCardContentHistory))
            history.accessibilityLabel = V3L("卡片修改历史")
            history.accessibilityIdentifier = "impress.composer.content-history"
            history.tintColor = ImpressV3Appearance.navigationActionInk
            navigationItem.rightBarButtonItems = [save, history]
        }

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        stack.axis = .vertical
        stack.spacing = ImpressV3Appearance.Metrics.sectionSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: ImpressV3Appearance.Metrics.sectionSpacing),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: ImpressV3Appearance.Metrics.screenInset),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -ImpressV3Appearance.Metrics.screenInset),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * ImpressV3Appearance.Metrics.screenInset)
        ])
        if #available(iOS 15.0, *) {
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor).isActive = true
        } else {
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor).isActive = true
        }

        typePicker.selectedSegmentIndex = currentType == .standard ? 0 :
            (currentType == .multipleChoice ? 1 : 2)
        // Native control, but with stronger selected contrast and hierarchy.
        ImpressV3Appearance.styleSegmentedControl(typePicker, prominent: false)
        typePicker.accessibilityLabel = V3L("卡片类型")
        typePicker.addTarget(self, action: #selector(typeDidChange), for: .valueChanged)
        // The control labels already name the types; a second visible
        // V3L("卡片类型") heading would add friction without information.
        stack.addArrangedSubview(ImpressV3Appearance.segmentedRow(typePicker))

        questionView.backgroundColor = ImpressV3Appearance.surface
        questionView.layer.cornerRadius = ImpressV3Appearance.Radius.field
        questionView.font = ImpressV3Appearance.Typography.body
        questionView.adjustsFontForContentSizeCategory = true
        questionView.textColor = ImpressV3Appearance.primaryText
        questionView.text = originalDraft.question
        questionView.textContainerInset = UIEdgeInsets(top: ImpressV3Appearance.Metrics.fieldPadding, left: ImpressV3Appearance.Metrics.fieldPadding, bottom: ImpressV3Appearance.Metrics.fieldPadding, right: ImpressV3Appearance.Metrics.fieldPadding)
        questionView.heightAnchor.constraint(greaterThanOrEqualToConstant: ImpressV3Appearance.Metrics.questionEditorMinHeight).isActive = true
        questionView.accessibilityLabel = V3L("问题")
        ImpressSpeechAccessory.install(on: questionView)
        stack.addArrangedSubview(makeLabeledGroup(V3L("问题"), child: questionView))
        let cameraOCR = UIButton(type: .system)
        ImpressV3Appearance.styleQuietButton(cameraOCR, title: V3L("拍照输入"),
                                              symbol: "text.viewfinder")
        cameraOCR.accessibilityIdentifier = "impress.composer.ocr-camera"
        cameraOCR.addTarget(self, action: #selector(captureQuestionText),
                            for: .touchUpInside)
        stack.addArrangedSubview(cameraOCR)

        configureQA()
        configureChoices()
        configurePhoto()
        stack.addArrangedSubview(qaSection)
        stack.addArrangedSubview(choiceSection)
        stack.addArrangedSubview(photoSection)
        updateVisibleType()
    }

    private func verticalStack(spacing: CGFloat = ImpressV3Appearance.Metrics.rowSpacing) -> UIStackView {
        let v = UIStackView()
        v.axis = .vertical
        v.spacing = spacing
        return v
    }

    private func caption(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = ImpressV3Appearance.Typography.supporting
        label.adjustsFontForContentSizeCategory = true
        label.textColor = ImpressV3Appearance.secondaryText
        label.numberOfLines = 0
        return label
    }

    private func makeLabeledGroup(_ title: String, child: UIView) -> UIStackView {
        let group = verticalStack()
        let heading = UILabel()
        heading.text = title
        heading.font = ImpressV3Appearance.Typography.heading
        heading.adjustsFontForContentSizeCategory = true
        group.addArrangedSubview(heading)
        group.addArrangedSubview(child)
        return group
    }

    private func configureQA() {
        qaSection.axis = .vertical
        qaSection.spacing = ImpressV3Appearance.Metrics.rowSpacing
        answerView.backgroundColor = ImpressV3Appearance.surface
        answerView.layer.cornerRadius = ImpressV3Appearance.Radius.field
        answerView.font = ImpressV3Appearance.Typography.body
        answerView.adjustsFontForContentSizeCategory = true
        answerView.textColor = ImpressV3Appearance.primaryText
        answerView.text = currentType == .multipleChoice
            ? choiceExplanationDraft : standardAnswerDraft
        answerView.textContainerInset = UIEdgeInsets(top: ImpressV3Appearance.Metrics.fieldPadding, left: ImpressV3Appearance.Metrics.fieldPadding, bottom: ImpressV3Appearance.Metrics.fieldPadding, right: ImpressV3Appearance.Metrics.fieldPadding)
        answerView.heightAnchor.constraint(greaterThanOrEqualToConstant: ImpressV3Appearance.Metrics.answerEditorMinHeight).isActive = true
        ImpressSpeechAccessory.install(on: answerView)
        answerView.accessibilityLabel = V3L("答案")
        let answerGroup = makeLabeledGroup(V3L("答案"), child: answerView)
        answerTitleLabel = answerGroup.arrangedSubviews.first as? UILabel
        qaSection.addArrangedSubview(answerGroup)
    }

    private func configureChoices() {
        choiceSection.axis = .vertical
        choiceSection.spacing = ImpressV3Appearance.Metrics.sectionSpacing
        choiceMode.selectedSegmentIndex = originalDraft.allowsMultipleCorrect ? 1 : 0
        ImpressV3Appearance.styleSegmentedControl(choiceMode, prominent: false)
        choiceMode.accessibilityLabel = V3L("单选或多选")
        choiceMode.addTarget(self, action: #selector(modeDidChange), for: .valueChanged)
        choiceSection.addArrangedSubview(
            ImpressV3Appearance.segmentedRow(choiceMode, compact: true))
        optionList.axis = .vertical
        optionList.spacing = ImpressV3Appearance.Metrics.choiceSpacing
        choiceSection.addArrangedSubview(makeLabeledGroup(V3L("选项（点选正确答案）"), child: optionList))
        addOptionButton.setTitle(V3L("添加选项"), for: .normal)
        ImpressV3Appearance.styleQuietButton(
            addOptionButton, title: V3L("添加选项"), symbol: "plus")
        addOptionButton.addTarget(self, action: #selector(addOption), for: .touchUpInside)
        choiceSection.addArrangedSubview(addOptionButton)
        choiceSection.addArrangedSubview(caption(V3L("正确答案直接点击圆形标记；单选与多选均使用同一套 FSRS 复习评分。")))
        renderOptionRows()
    }

    @objc private func captureQuestionText() {
        ImpressSpeechAccessory.presentOCR(for: questionView)
    }

    private func configurePhoto() {
        photoSection.axis = .vertical
        photoSection.spacing = ImpressV3Appearance.Metrics.sectionSpacing
        imageButton.setTitle(V3L("从相册选择图片或视频"), for: .normal)
        ImpressV3Appearance.styleQuietButton(
            imageButton, title: V3L("从相册选择图片或视频"), symbol: "photo.on.rectangle")
        imageButton.addTarget(self, action: #selector(selectPhoto), for: .touchUpInside)
        photoSection.addArrangedSubview(imageButton)
        ImpressV3Appearance.styleQuietButton(videoCaptureButton,
            title: V3L("拍摄视频"), symbol: "video.badge.plus")
        videoCaptureButton.accessibilityIdentifier = "impress.card.video.camera"
        videoCaptureButton.addTarget(self, action: #selector(captureVideo),
                                     for: .touchUpInside)
        photoSection.addArrangedSubview(videoCaptureButton)
        imagePreview.contentMode = .scaleAspectFit
        imagePreview.backgroundColor = ImpressV3Appearance.surface
        imagePreview.layer.cornerRadius = ImpressV3Appearance.Radius.field
        imagePreview.clipsToBounds = true
        imagePreview.heightAnchor.constraint(equalToConstant: ImpressV3Appearance.Metrics.photoPreviewHeight).isActive = true
        imagePreview.image = imageData.flatMap { UIImage(data: $0) }
        imagePreview.isHidden = imageData == nil
        photoSection.addArrangedSubview(imagePreview)
        photoStatus = caption(V3L("仅访问所选图片；取消不修改草稿，保存前在本机压缩。"))
        photoSection.addArrangedSubview(photoStatus)
        ImpressV3Appearance.styleQuietButton(
            removeExistingVideoButton, title: V3L("移除视频"), symbol: "minus.circle")
        removeExistingVideoButton.accessibilityIdentifier = "impress.card.video.remove"
        removeExistingVideoButton.isHidden = !editingHasVideo
        removeExistingVideoButton.addTarget(
            self, action: #selector(markExistingVideoForRemoval), for: .touchUpInside)
        photoSection.addArrangedSubview(removeExistingVideoButton)
        ImpressV3Appearance.styleQuietButton(cancelVideoButton,
            title: V3L("取消视频处理"), symbol: "xmark.circle")
        cancelVideoButton.addTarget(self, action: #selector(cancelVideoImport), for: .touchUpInside)
        cancelVideoButton.isHidden = true
        photoSection.addArrangedSubview(cancelVideoButton)
    }

    @objc private func typeDidChange() {
        switch currentType {
        case .standard: standardAnswerDraft = answerView.text ?? ""
        case .multipleChoice: choiceExplanationDraft = answerView.text ?? ""
        case .image: break
        }
        switch typePicker.selectedSegmentIndex {
        case 1: currentType = .multipleChoice
        case 2: currentType = .image
        default: currentType = .standard
        }
        answerView.text = currentType == .multipleChoice
            ? choiceExplanationDraft : standardAnswerDraft
        updateVisibleType()
    }

    private func updateVisibleType() {
        qaSection.isHidden = currentType == .image
        answerTitleLabel?.text = currentType == .multipleChoice
            ? V3L("解析（可选）") : V3L("答案")
        answerView.accessibilityLabel = answerTitleLabel?.text
        choiceSection.isHidden = currentType != .multipleChoice
        photoSection.isHidden = currentType != .image
    }

    @objc private func modeDidChange() {
        // Do not silently delete selected answers when changing modes.
        // If multiple are still selected in single mode, save validation explains why.
        renderOptionRows()
    }

    private func syncOptionEdits() {
        for view in optionList.arrangedSubviews {
            guard let row = view as? OptionRow,
                  let index = choiceDrafts.firstIndex(where: { $0.id == row.id }) else { continue }
            choiceDrafts[index].text = row.field.text ?? ""
        }
    }

    private func renderOptionRows() {
        syncOptionEdits()
        optionList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, choice) in choiceDrafts.enumerated() {
            let row = OptionRow(id: choice.id, index: index, correct: choice.isCorrect,
                                isMulti: choiceMode.selectedSegmentIndex == 1, text: choice.text)
            row.onSelect = { [weak self] id in self?.selectAnswer(id: id) }
            row.onDelete = { [weak self] id in self?.deleteOption(id: id) }
            row.onMove = { [weak self] id, offset in self?.moveOption(id: id, by: offset) }
            optionList.addArrangedSubview(row)
        }
    }

    private func selectAnswer(id: UUID) {
        syncOptionEdits()
        let single = choiceMode.selectedSegmentIndex == 0
        if single {
            for i in choiceDrafts.indices { choiceDrafts[i].isCorrect = choiceDrafts[i].id == id }
        } else if let i = choiceDrafts.firstIndex(where: { $0.id == id }) {
            choiceDrafts[i].isCorrect.toggle()
        }
        renderOptionRows()
    }

    @objc private func addOption() {
        guard choiceDrafts.count < 12 else { return }
        syncOptionEdits()
        choiceDrafts.append(.init())
        renderOptionRows()
    }

    private func deleteOption(id: UUID) {
        guard choiceDrafts.count > 2 else { return }
        syncOptionEdits()
        choiceDrafts.removeAll { $0.id == id }
        renderOptionRows()
    }

    private func moveOption(id: UUID, by offset: Int) {
        syncOptionEdits()
        guard let index = choiceDrafts.firstIndex(where: { $0.id == id }),
              choiceDrafts.indices.contains(index + offset) else { return }
        choiceDrafts.swapAt(index, index + offset)
        renderOptionRows()
    }

    private func draft() -> ImpressV3CardDraft {
        // This reads form controls without changing any stored business data.
        syncOptionEdits()
        let currentAnswer = currentType == .image
            ? standardAnswerDraft : (answerView.text ?? "")
        return ImpressV3CardDraft(kind: currentType,
                                  question: questionView.text,
                                  answer: currentAnswer,
                                  choices: choiceDrafts,
                                  allowsMultipleCorrect: choiceMode.selectedSegmentIndex == 1,
                                  imageData: imageData,
                                  sourceNotePath: originalDraft.sourceNotePath)
    }

    @objc private func markExistingVideoForRemoval() {
        guard editingHasVideo, currentType == .image,
              !processingPhoto, !saving else { return }
        stagedVideo?.discard()
        stagedVideo = nil
        removeExistingVideoPending = true
        // Removing a video must not remove its current JPEG cover or history.
        imageData = originalDraft.imageData
        imagePreview.image = imageData.flatMap(UIImage.init(data:))
        imagePreview.isHidden = imageData == nil
        removeExistingVideoButton.isHidden = true
        photoStatus.text = V3L("视频已标记移除；保存后仅保留封面图片。")
    }

    // Keep the visible composer and the containing sheet in one save-lock
    // state. UIKit may consult either controller during modal transitions.
    // A pending WCDB CAS must never permit interactive dismissal.
    private func setSaveLock(_ locked: Bool) {
        saving = locked
        saveItem?.isEnabled = !locked
        navigationItem.leftBarButtonItem?.isEnabled = !locked
        isModalInPresentation = locked
        navigationController?.isModalInPresentation = locked
    }

    @objc private func saveCard() {
        guard !saving, !processingPhoto else { return }
        let input: WCDBV3CardInput
        do {
            input = try draft().validatedInput(cardID: editingCardID ?? createdCardID)
        } catch {
            showProblem(error.localizedDescription)
            return
        }
        // A staged movie is not a saved card. The integration owner must install
        // its immutable file pair and atomically bind the metadata to the exact
        // WCDB content CAS before this editor can acknowledge success.
        let video = currentType == .image ? stagedVideo : nil
        let removeVideo = currentType == .image &&
            removeExistingVideoPending && video == nil
        guard !removeVideo || onRemoveVideo != nil else {
            showProblem(V3L("无法移除视频；请重试。"))
            return
        }
        guard video == nil || onSaveVideo != nil else {
            showProblem(V3L("视频保存与备份尚未完成接入，当前草稿未保存。"))
            return
        }
        guard video != nil || onSave != nil || (removeVideo && onRemoveVideo != nil) else { return }
        if let video {
            guard video.reference.cardID == input.cardID,
                  video.reference.contentRevision == targetVideoRevision else {
                showProblem(V3L("卡片版本已变化，请重新选择视频。"))
                return
            }
        }
        // A WCDB CAS may still be running after the save tap. Do not allow
        // Cancel or sheet swipe to discard its staged movie before readback.
        setSaveLock(true)
        Task { [weak self] in
            guard let self else { return }
            do {
                if let video, let handler = self.onSaveVideo {
                    try await handler(input, video)
                } else if removeVideo, let handler = self.onRemoveVideo {
                    try await handler(input)
                } else if let handler = self.onSave {
                    try await handler(input)
                } else {
                    throw CocoaError(.userCancelled)
                }
                self.stagedVideo?.discard()
                self.stagedVideo = nil
                self.isModalInPresentation = false
                self.navigationController?.isModalInPresentation = false
                self.dismiss(animated: true)
            } catch {
                self.setSaveLock(false)
                self.showProblem("卡片未保存：" + error.localizedDescription)
            }
        }
    }

    private func showProblem(_ text: String) {
        let alert = UIAlertController(title: V3L("无法保存"), message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        present(alert, animated: true)
    }

    @objc private func cancel() {
        // A dismiss during an in-flight CAS can otherwise race with staged
        // media cleanup and falsely promise that nothing was saved.
        guard !saving else { return }
        let unchanged = questionView.text == originalDraft.question &&
            answerView.text == originalDraft.answer &&
            currentType == originalDraft.kind &&
            imageData == originalDraft.imageData && stagedVideo == nil &&
            !removeExistingVideoPending
        syncOptionEdits()
        if unchanged && choiceDrafts == originalDraft.choices {
            dismiss(animated: true)
            return
        }
        let alert = UIAlertController(title: V3L("放弃未保存的内容？"),
                                      message: V3L("取消不会写入 WCDB 或修改原始笔记。"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("继续编辑"), style: .cancel))
        alert.addAction(UIAlertAction(title: V3L("放弃"), style: .destructive) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    private var targetVideoRevision: Int? {
        if editingCardID == nil { return 0 }
        guard let expectedEditingContentRevision,
              expectedEditingContentRevision >= 0,
              expectedEditingContentRevision < Int.max else { return nil }
        return expectedEditingContentRevision + 1
    }

    @objc private func captureVideo() {
        guard !processingPhoto, !saving else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            showProblem(V3L("此设备不支持相机视频录制。"))
            return
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        picker.videoMaximumDuration = 60
        picker.videoQuality = .typeMedium
        picker.delegate = self
        present(picker, animated: true)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true) { [weak self] in
            guard let self, let source = info[.mediaURL] as? URL else { return }
            do {
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("impress-captured-\(UUID().uuidString).mov")
                try FileManager.default.copyItem(at: source, to: copy)
                guard let provider = NSItemProvider(contentsOf: copy) else {
                    try? FileManager.default.removeItem(at: copy)
                    throw ImpressCardVideoImportCoordinator.Failure.unsupportedVideo
                }
                self.removeCapturedVideoSource()
                self.capturedVideoSource = copy
                self.beginVideoSelection(provider)
            } catch {
                self.showProblem(error.localizedDescription)
            }
        }
    }

    private func removeCapturedVideoSource() {
        if let url = capturedVideoSource {
            try? FileManager.default.removeItem(at: url)
            capturedVideoSource = nil
        }
    }

    @objc private func selectPhoto() {
        guard !processingPhoto, !saving else { return }
        var cfg = PHPickerConfiguration()
        cfg.selectionLimit = 1
        cfg.filter = .any(of: [.images, .videos])
        cfg.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: cfg)
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func cancelVideoImport() {
        activeVideoImportToken = UUID()
        videoImporter.cancel()
        removeCapturedVideoSource()
        processingPhoto = false
        saveItem?.isEnabled = !saving
        cancelVideoButton.isHidden = true
        photoStatus.text = V3L("视频处理已取消，已有草稿未修改。")
    }

    private func beginVideoSelection(_ provider: NSItemProvider) {
        guard let targetVideoRevision else {
            removeCapturedVideoSource()
            showProblem(V3L("无法确定卡片内容版本，请重新打开编辑器。"))
            return
        }
        let sourceForSelection = capturedVideoSource
        let token = UUID()
        activeVideoImportToken = token
        processingPhoto = true
        saveItem?.isEnabled = false
        cancelVideoButton.isHidden = false
        photoStatus.text = V3L("准备本机视频…")
        videoImporter.start(provider: provider, cardID: editingCardID ?? createdCardID,
            targetContentRevision: targetVideoRevision, presenter: self,
            progress: { [weak self] fraction in
                self?.photoStatus.text = String(format: "正在本机压缩视频 · %d%%",
                    Int(max(0, min(100, fraction * 100))))
            }, completion: { [weak self] result in
                guard let self, self.activeVideoImportToken == token else {
                    if case .success(let stage) = result { stage.discard() }
                    return
                }
                self.processingPhoto = false
                if self.capturedVideoSource == sourceForSelection {
                    self.removeCapturedVideoSource()
                }
                self.saveItem?.isEnabled = !self.saving
                self.cancelVideoButton.isHidden = true
                switch result {
                case .success(let stage):
                    guard let cover = try? Data(contentsOf: stage.coverURL),
                          !cover.isEmpty else {
                        stage.discard()
                        self.photoStatus.text = V3L("视频未修改，请重试。")
                        self.showProblem(V3L("无法读取视频封面。"))
                        return
                    }
                    self.stagedVideo?.discard()
                    self.stagedVideo = stage
                    self.removeExistingVideoPending = false
                    self.removeExistingVideoButton.isHidden = !self.editingHasVideo
                    self.imageData = cover
                    self.imagePreview.image = UIImage(data: cover)
                    self.imagePreview.isHidden = false
                    self.photoStatus.text = "视频已准备好 · \(stage.reference.videoBytes / 1_048_576) MiB"
                case .failure(let error):
                    self.photoStatus.text = V3L("视频未修改，请重试。")
                    if case ImpressCardVideoImportCoordinator.Failure.staleSelection = error {
                        return
                    }
                    self.showProblem(error.localizedDescription)
                }
            })
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        if provider.registeredTypeIdentifiers.contains(where: {
            UTType($0)?.conforms(to: .movie) == true
        }) {
            beginVideoSelection(provider)
            return
        }
        let requestID = UUID()
        imageRequestID = requestID
        let fileType = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) ?? UTType.image.identifier
        guard provider.hasItemConformingToTypeIdentifier(fileType) else {
            showProblem(V3L("选中的项目不是受支持的图片。"))
            return
        }
        processingPhoto = true
        saveItem?.isEnabled = false
        photoStatus.text = V3L("正在本机压缩图片…")
        let kind: ImpressImageOptimizer.ContentKind =
            UTType(fileType)?.conforms(to: .png) == true ? .document : .photo
        provider.loadFileRepresentation(forTypeIdentifier: fileType) { [weak self] temporary, error in
            // Process inside the item-provider callback: its temporary file
            // is deleted once the callback returns. Never decode full 48MP.
            guard let temporary, let source = CGImageSourceCreateWithURL(temporary as CFURL, nil) else {
                DispatchQueue.main.async { [weak self] in
                    // A stale iCloud failure cannot unlock a new image request
                    // or show an alert after this editor has been dismissed.
                    guard let self, self.imageRequestID == requestID else { return }
                    self.photoFailed(error?.localizedDescription ?? V3L("图片读取失败或 iCloud 尚未下载。"))
                }
                return
            }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: kind == .document ? 2000 : 1280
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.imageRequestID == requestID else { return }
                    self.photoFailed(V3L("无法读取图片缩略图。"))
                }
                return
            }
            let image = UIImage(cgImage: thumbnail)
            let result = Result { try ImpressImageOptimizer.optimize(image, kind: kind) }
            DispatchQueue.main.async {
                guard let self, self.imageRequestID == requestID else { return }
                self.processingPhoto = false
                self.saveItem?.isEnabled = !self.saving
                switch result {
                case .success(let data):
                    self.stagedVideo?.discard()
                    self.stagedVideo = nil
                    if self.editingHasVideo {
                        self.removeExistingVideoPending = true
                        self.removeExistingVideoButton.isHidden = true
                    }
                    self.imageData = data
                    self.imagePreview.image = UIImage(data: data)
                    self.imagePreview.isHidden = false
                    self.photoStatus.text = "图片已准备好 · \(data.count / 1024) KB"
                case .failure(let reason):
                    self.showProblem("压缩失败：" + reason.localizedDescription)
                    self.photoStatus.text = V3L("图片未修改，请重试。")
                }
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            imageRequestID = UUID()
            activeVideoImportToken = UUID()
            videoImporter.cancel()
            removeCapturedVideoSource()
            stagedVideo?.discard()
            stagedVideo = nil
        }
    }

    private func photoFailed(_ reason: String) {
        processingPhoto = false
        saveItem?.isEnabled = !saving
        photoStatus.text = V3L("图片未修改，请重试。")
        showProblem(reason)
    }

    private final class OptionRow: UIStackView {
        let id: UUID
        let field = UITextField()
        var onSelect: ((UUID) -> Void)?
        var onDelete: ((UUID) -> Void)?
        var onMove: ((UUID, Int) -> Void)?

        init(id: UUID, index: Int, correct: Bool, isMulti: Bool, text: String) {
            self.id = id
            super.init(frame: .zero)
            axis = .horizontal
            alignment = .center
            spacing = ImpressV3Appearance.Metrics.rowSpacing
            let mark = UIButton(type: .system)
            mark.setImage(UIImage(systemName: correct
                                  ? (isMulti ? "checkmark.square.fill" : "largecircle.fill.circle")
                                  : (isMulti ? "square" : "circle")), for: .normal)
            mark.tintColor = ImpressV3Appearance.accent
            mark.widthAnchor.constraint(equalToConstant: ImpressV3Appearance.Metrics.tapTarget).isActive = true
            mark.heightAnchor.constraint(equalToConstant: ImpressV3Appearance.Metrics.tapTarget).isActive = true
            mark.accessibilityLabel = "选项 \(index + 1) \(correct ? "正确" : "未标记")"
            mark.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.onSelect?(self.id)
            }, for: .touchUpInside)
            field.text = text
            field.placeholder = "选项 \(index + 1)"
            ImpressV3Appearance.styleTextField(field)
            ImpressSpeechAccessory.install(on: field)
            field.accessibilityLabel = "选项 \(index + 1) 内容"
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: ImpressV3Appearance.Metrics.controlHeight).isActive = true
            let actions = UIButton(type: .system)
            actions.setImage(UIImage(systemName: "ellipsis"), for: .normal)
            actions.widthAnchor.constraint(equalToConstant: ImpressV3Appearance.Metrics.tapTarget).isActive = true
            actions.heightAnchor.constraint(equalToConstant: ImpressV3Appearance.Metrics.tapTarget).isActive = true
            actions.tintColor = ImpressV3Appearance.secondaryText
            actions.accessibilityLabel = "调整或删除选项 \(index + 1)"
            actions.menu = UIMenu(children: [
                UIAction(title: V3L("上移"), image: UIImage(systemName: "arrow.up")) { [weak self] _ in
                    guard let self else { return }; self.onMove?(self.id, -1)
                },
                UIAction(title: V3L("下移"), image: UIImage(systemName: "arrow.down")) { [weak self] _ in
                    guard let self else { return }; self.onMove?(self.id, 1)
                },
                UIAction(title: V3L("删除"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    guard let self else { return }; self.onDelete?(self.id)
                }
            ])
            actions.showsMenuAsPrimaryAction = true
            addArrangedSubview(mark)
            addArrangedSubview(field)
            addArrangedSubview(actions)
        }

        required init(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    }
}
