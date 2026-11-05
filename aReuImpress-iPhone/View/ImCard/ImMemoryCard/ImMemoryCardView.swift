//
//  ImMemoryCardView.swift
//  aReuImpress-iPhone
//
//  记忆卡片视图 - 标准卡片类型的主要内容视图
//  功能：显示问题和答案、处理翻转动画、管理操作按钮
//  特色：支持语音播放、编辑功能、图片显示、划线标注
//
//  Created by aReu on 7/11/25.
//

import UIKit
import MarkdownKit

/// 记忆卡片视图
/// 负责展示标准类型卡片的内容，包括问题显示、答案展示和各种交互功能
/// 支持暗黑模式和无障碍访问，遵循苹果HIG设计规范
class ImMemoryCardView: UIView
{
    private var questionTextViewTopConstraint: NSLayoutConstraint!
    private var questionTextViewHeightConstraint: NSLayoutConstraint!
    private var questionTextViewCenterYConstraint: NSLayoutConstraint!
    private var answerContainerTopConstraintToCenter: NSLayoutConstraint!
    private var answerContainerTopConstraintToQuestionTextView: NSLayoutConstraint!

    private let cardView: UIView = {
        let view = UIView()
        return view
    }()

    let questionTextView: ImExtractTextView = {
        let textView = ImExtractTextView()
        textView.backgroundColor = .clear
        textView.font = UIFont.preferredFont(forTextStyle: .title1)
        textView.isEditable = false
        textView.textColor = contentColor
        textView.isScrollEnabled = false
        textView.textAlignment = .left
        textView.showsVerticalScrollIndicator = false
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        return textView
    }()

    // 答案容器
    private let answerContainerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.alpha = 0
        view.backgroundColor = .clear
        return view
    }()

    private let answerTextView: ImExtractTextView = {
        let textView = ImExtractTextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.textAlignment = .left
        textView.isScrollEnabled = true
        textView.showsVerticalScrollIndicator = false
        return textView
    }()

    private let answerImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    private var usesCompactV3Style = false
    private var isAnswerShown = false
    var answerIsRevealed: Bool { isAnswerShown }

    private var cardModel: ImCardModel?
    /// Used only for V3 video cards; the image lives inside the unrevealed
    /// answer container, so neither its cover nor play icon leaks early.
    var showsVideoPlayIndicator = false {
        didSet { updateVideoPlayOverlay() }
    }
    private let videoPlayOverlay = UIImageView()
    private func updateVideoPlayOverlay() {
        videoPlayOverlay.removeFromSuperview()
        guard showsVideoPlayIndicator else { return }
        videoPlayOverlay.image = UIImage(systemName: "play.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 42, weight: .medium))
        videoPlayOverlay.tintColor = ImpressV3Appearance.accent
        videoPlayOverlay.isUserInteractionEnabled = false
        videoPlayOverlay.translatesAutoresizingMaskIntoConstraints = false
        answerImageView.addSubview(videoPlayOverlay)
        NSLayoutConstraint.activate([
            videoPlayOverlay.centerXAnchor.constraint(equalTo: answerImageView.centerXAnchor),
            videoPlayOverlay.centerYAnchor.constraint(equalTo: answerImageView.centerYAnchor)
        ])
        answerImageView.isAccessibilityElement = true
        answerImageView.accessibilityIdentifier = "impress.review.video.play"
        answerImageView.accessibilityLabel = V3L("视频封面，轻点播放")
    }
    var onImageTapped: (() -> Void)?
    var onFullQuestionRequested: (() -> Void)?
    /// V3 observes answer visibility; legacy screens need not subscribe.
    var onAnswerVisibilityChanged: ((Bool) -> Void)?
    func revealAnswerIfNeeded() {
        if !isAnswerShown { showAnswer() }
    }

    // MARK: - Public Methods
    func updateCardContent(_ model: ImCardModel) {
        self.cardModel = model
        if usesCompactV3Style {
            questionTextView.setMarkdownText(model.question ?? "")
        } else {
            questionTextView.text = model.question
        }
        if usesCompactV3Style {
            ImpressV3Appearance.styleFlashcardText(questionTextView, question: true)
        }
        updateQuestionTextViewHeight()

        // 更新答案内容
        let cardType = CardType(rawValue: model.cardType ?? 0) ?? .standard
        switch cardType {
        case .image:
            if let imageData = model.imageData {
                answerImageView.image = UIImage(data: imageData)
            }
        default:
            answerTextView.setMarkdownText(model.answer ?? "")
            if usesCompactV3Style { ImpressV3Appearance.styleFlashcardText(answerTextView, question: false) }
        }
    }

    // MARK: - Initialization
    convenience init(model: ImCardModel, v3Style: Bool = false)
    {
        self.init()
        self.usesCompactV3Style = v3Style
        if v3Style {
            // High-priority question text is primary label color, not muted gray.
            questionTextView.textColor = ImpressV3Appearance.primaryText
            questionTextView.font = ImpressV3Appearance.Typography.flashQuestion
            answerTextView.font = ImpressV3Appearance.Typography.flashAnswer
            // Limit only the visual projection. Never truncate stored Markdown.
            questionTextView.isScrollEnabled = false
            questionTextView.textContainer.maximumNumberOfLines = 3
            questionTextView.textContainer.lineBreakMode = .byTruncatingTail
            questionTextView.showsVerticalScrollIndicator = false
            answerTextView.showsVerticalScrollIndicator = true
            questionTextView.isSelectable = true
            answerTextView.isSelectable = true
            answerContainerView.accessibilityElementsHidden = true
            questionTextView.adjustsFontForContentSizeCategory = true
            answerTextView.adjustsFontForContentSizeCategory = true
        }
        self.cardModel = model
        if v3Style {
            questionTextView.setMarkdownText(model.question ?? "")
            ImpressV3Appearance.styleFlashcardText(questionTextView, question: true)
        } else {
            questionTextView.text = model.question
        }
        setupUI()
        configureAnswerView(for: model)
        updateQuestionTextViewHeight()
        setupActions()
    }
    
    override func layoutSubviews()
    {
        super.layoutSubviews()
        // Reconcile with the current text width synchronously. Async-only
        // sizing left a newly presented question at the former 44pt placeholder,
        // clipping a three-line question to one/two lines until another layout.
        // The height setter is idempotent (changes > 1pt only).
        updateQuestionTextViewHeight()
    }

    // MARK: - Setup
    private func setupUI()
    {
        cardView.frame = bounds
        addSubview(cardView)
        cardView.addSubview(questionTextView)
        cardView.addSubview(answerContainerView)

        cardView.translatesAutoresizingMaskIntoConstraints = false
        questionTextView.translatesAutoresizingMaskIntoConstraints = false

        // V3.1 adapts to iPhone SE and keyboard/sheet safe areas. The
        // former 300×400 priority-999 minimum conflicted on compact screens.
        let cardViewWidthConstraint = cardView.widthAnchor.constraint(equalTo: safeAreaLayoutGuide.widthAnchor)
        let cardViewHeightConstraint = cardView.heightAnchor.constraint(equalTo: safeAreaLayoutGuide.heightAnchor)
        let cardViewMinWidthConstraint = cardView.widthAnchor.constraint(greaterThanOrEqualToConstant: usesCompactV3Style ? 220 : 300)
        let cardViewMinHeightConstraint = cardView.heightAnchor.constraint(greaterThanOrEqualToConstant: usesCompactV3Style ? 200 : 400)
        cardViewMinWidthConstraint.priority = UILayoutPriority(usesCompactV3Style ? 250 : 999)
        cardViewMinHeightConstraint.priority = UILayoutPriority(usesCompactV3Style ? 250 : 999)

        NSLayoutConstraint.activate([
            cardView.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.centerYAnchor),
            cardViewWidthConstraint,
            cardViewHeightConstraint,
            cardViewMinWidthConstraint,
            cardViewMinHeightConstraint,
        ])


        // questionTextView 约束
        questionTextViewTopConstraint = questionTextView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: usesCompactV3Style ? 64 : 32)
        questionTextViewCenterYConstraint = questionTextView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor)
        questionTextViewCenterYConstraint.isActive = true

        // A card may be rendered before it has a window/safe-area width.
        // Use a true three-line initial viewport instead of a 44pt placeholder.
        // Once width is known, updateQuestionTextViewHeight() shrinks short
        // questions to their measured 1/2 lines and retains a 3-line maximum.
        let initialQuestionHeight: CGFloat = usesCompactV3Style
            ? (questionTextView.font?.lineHeight ??
                ImpressV3Appearance.Typography.flashQuestion.lineHeight) * 3 +
                questionTextView.textContainerInset.top +
                questionTextView.textContainerInset.bottom + 3
            : 44
        questionTextViewHeightConstraint = questionTextView.heightAnchor.constraint(
            equalToConstant: initialQuestionHeight)
        // 设置高度约束优先级为高但非必需，允许在空间不足时压缩
        questionTextViewHeightConstraint.priority = UILayoutPriority(750)
        questionTextViewHeightConstraint.isActive = true
    
        NSLayoutConstraint.activate([
            questionTextView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: defaultSpacing),
            questionTextView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -defaultSpacing),
        ])

        answerContainerTopConstraintToCenter = answerContainerView.topAnchor.constraint(equalTo: cardView.centerYAnchor)
        answerContainerTopConstraintToQuestionTextView = answerContainerView.topAnchor.constraint(equalTo: questionTextView.bottomAnchor, constant: 8)
        answerContainerTopConstraintToCenter.isActive = true

        let answerContainerViewBottomConstraint = answerContainerView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -defaultSpacing)
        answerContainerViewBottomConstraint.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            answerContainerView.leadingAnchor.constraint(equalTo: questionTextView.leadingAnchor),
            answerContainerView.trailingAnchor.constraint(equalTo: questionTextView.trailingAnchor),
            answerContainerViewBottomConstraint
        ])
    }

    private func configureAnswerView(for model: ImCardModel) {
        // Clear previous views
        answerContainerView.subviews.forEach { $0.removeFromSuperview() }

        let cardType = CardType(rawValue: model.cardType ?? 0) ?? .standard
        var currentAnswerView: UIView

        switch cardType {
        case .image:
            if let imageData = model.imageData {
                answerImageView.image = UIImage(data: imageData)
            }
            answerImageView.isUserInteractionEnabled = true
            let imageTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleImageTap))
            answerImageView.addGestureRecognizer(imageTapGesture)
            currentAnswerView = answerImageView
        default: // .standard, .multipleChoice
            answerTextView.setMarkdownText(model.answer ?? "")
            if usesCompactV3Style { ImpressV3Appearance.styleFlashcardText(answerTextView, question: false) }
            currentAnswerView = answerTextView
        }
        
        answerContainerView.addSubview(currentAnswerView)
        currentAnswerView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            currentAnswerView.topAnchor.constraint(equalTo: answerContainerView.topAnchor),
            currentAnswerView.leadingAnchor.constraint(equalTo: answerContainerView.leadingAnchor),
            currentAnswerView.trailingAnchor.constraint(equalTo: answerContainerView.trailingAnchor),
            currentAnswerView.bottomAnchor.constraint(equalTo: answerContainerView.bottomAnchor)
        ])
    }
    
    private func updateQuestionTextViewHeight(revealed: Bool? = nil)
    {
        // 增加安全检查，确保cardView有有效尺寸
        guard cardView.bounds.width > 0 && cardView.bounds.height > 0 else {
            return
        }

        let viewportWidth = questionTextView.bounds.width > 0
            ? questionTextView.bounds.width : cardView.bounds.width - 2 * defaultSpacing
        let maxWidth = viewportWidth - questionTextView.textContainerInset.left -
            questionTextView.textContainerInset.right -
            2 * questionTextView.textContainer.lineFragmentPadding
        guard maxWidth > 0 else { return }
        let estimatedSize = questionTextView.sizeThatFits(
            CGSize(width: viewportWidth, height: CGFloat.greatestFiniteMagnitude))
        var largestLine = questionTextView.font?.lineHeight ?? 25
        if let attributed = questionTextView.attributedText, attributed.length > 0 {
            attributed.enumerateAttribute(.font,
                in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
                if let font = value as? UIFont { largestLine = max(largestLine, font.lineHeight) }
            }
        }
        let threeLines = largestLine * 3 +
            questionTextView.textContainerInset.top + questionTextView.textContainerInset.bottom + 2

        // Cap only the viewport, not the original Markdown. After reveal,
        // reserve enough visible space for a separately scrollable answer.
        let split = revealed ?? isAnswerShown
        let available = max(56, cardView.bounds.height -
            (usesCompactV3Style ? 32 : 64))
        let maximum = usesCompactV3Style
            ? min(threeLines, split ? max(48, available * 0.42) : available)
            : estimatedSize.height
        let visibleLines = ImpressV3QuestionLayout.visibleLineCount(
            questionTextView.attributedText, width: maxWidth)
        let exactVisibleHeight = CGFloat(min(3, max(1, visibleLines))) * largestLine +
            questionTextView.textContainerInset.top + questionTextView.textContainerInset.bottom + 3
        let target = usesCompactV3Style
            ? min(exactVisibleHeight, maximum) : min(estimatedSize.height, maximum)
        guard abs(questionTextViewHeightConstraint.constant - target) > 1.0 else { return }
        questionTextViewHeightConstraint.constant = target
        // 移除强制布局调用，避免在布局过程中触发新的布局周期
    }

    private func setupActions()
    {
        // R03 requires the explicit external “查看答案” button. Tapping or
        // selecting text on the question must not unexpectedly reveal it.
        // Legacy cards retain their original tap-to-reveal contract.
        if usesCompactV3Style {
            let fullTextTap = UITapGestureRecognizer(target: self,
                action: #selector(openFullQuestionIfTruncated))
            fullTextTap.cancelsTouchesInView = false
            questionTextView.addGestureRecognizer(fullTextTap)
            questionTextView.accessibilityHint = V3L("题干超过三行时，轻点阅读完整原文")
            return
        }
        let tapGesture = UITapGestureRecognizer(target: self,
                                                action: #selector(toggleAnswer))
        cardView.addGestureRecognizer(tapGesture)
        //
        let questionTapGesture = UITapGestureRecognizer(target: self,
                                                        action: #selector(toggleAnswer))
        questionTextView.addGestureRecognizer(questionTapGesture)
        questionTextView.isUserInteractionEnabled = true
    }

    var isQuestionTruncated: Bool {
        let width = questionTextView.bounds.width -
            questionTextView.textContainerInset.left -
            questionTextView.textContainerInset.right -
            2 * questionTextView.textContainer.lineFragmentPadding
        return ImpressV3QuestionLayout.isTruncated(
            questionTextView.attributedText, width: width)
    }

    @objc private func openFullQuestionIfTruncated() {
        guard usesCompactV3Style, isQuestionTruncated else { return }
        onFullQuestionRequested?()
    }

    @objc private func handleImageTap() {
        onImageTapped?()
    }

    // MARK: - Actions
    @objc private func toggleAnswer()
    {
        // In R03, revealed long answers remain readable and scrollable.
        // Incidental taps must not hide the answer or revoke rating readiness.
        if usesCompactV3Style && isAnswerShown { return }
        if !isAnswerShown {
            // 显示答案
            showAnswer()
        } else {
            // 隐藏答案，重新显示操作栏
            hideAnswer()
        }
    }

    private func showAnswer() {
        questionTextViewCenterYConstraint.isActive = false
        questionTextViewTopConstraint.isActive = true
        answerContainerTopConstraintToCenter.isActive = false
        answerContainerTopConstraintToQuestionTextView.isActive = true
        updateQuestionTextViewHeight(revealed: true)
        answerContainerView.accessibilityElementsHidden = false

        UIView.animate(withDuration: ImAnimationConfig.fadeAnimationDuration, animations: { [weak self] in
            guard let self = self else { return }
//            self.questionTextView.textColor = contentColor
            self.answerContainerView.alpha = 1
            self.layoutIfNeeded()
        }) { _ in
            self.isAnswerShown = true
            self.onAnswerVisibilityChanged?(true)
        }
    }

    private func hideAnswer() {
        questionTextViewTopConstraint.isActive = false
        questionTextViewCenterYConstraint.isActive = true
        answerContainerTopConstraintToQuestionTextView.isActive = false
        answerContainerTopConstraintToCenter.isActive = true
        updateQuestionTextViewHeight(revealed: false)
        answerContainerView.accessibilityElementsHidden = true

        UIView.animate(withDuration: ImAnimationConfig.fadeAnimationDuration, animations: { [weak self] in
            guard let self = self else { return }
//            self.questionTextView.textColor = contentColor
            self.answerContainerView.alpha = 0
            self.layoutIfNeeded()
        }) { _ in
            self.isAnswerShown = false
            self.onAnswerVisibilityChanged?(false)
        }
    }
}

 
/// Use actual attributed-text line fragments, not string length, for the
/// compact question projection shared by all V3 card types.
enum ImpressV3QuestionLayout {
    static func isTruncated(_ text: NSAttributedString?, width: CGFloat) -> Bool {
        visibleLineCount(text, width: width) > 3
    }

    static func visibleLineCount(_ text: NSAttributedString?, width: CGFloat) -> Int {
        guard let text, text.length > 0, width > 0 else { return 0 }
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let range = layout.glyphRange(for: container)
        var count = 0
        layout.enumerateLineFragments(forGlyphRange: range) { _, _, _, _, stop in
            count += 1
            if count > 3 { stop.pointee = true }
        }
        return count
    }
}
