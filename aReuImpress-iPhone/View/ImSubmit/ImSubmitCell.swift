//
//  ImSubmitCell.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 7/28/25.
//

import UIKit

protocol ImSubmitCellDelegate: AnyObject {
    func textViewDidChange(cell: ImSubmitCell)
}

/// Cell类型
enum ImSubmitCellType: String
{
    case input = "内容"
    case inputTitle = "标题"
    case submit = "提交"
    case llm = "大模型"
    case selectCardType = "卡片类型"
    case multipleChoiceOptions = "选项"
    case multipleChoiceCorrectAnswer = "正确答案索引"
    case imagePicker = "选择图片"
    
    /// 是否为输入类型Cell
    var isInput: Bool {
        switch self {
        case .input, .inputTitle, .multipleChoiceOptions, .multipleChoiceCorrectAnswer:
            return true
        default:
            return false
        }
    }
}

class ImSubmitCell: ImBaseTableViewCell, UITextViewDelegate
{
    weak var delegate: ImSubmitCellDelegate?
    
    // MARK: - Callbacks
    var onCardTypeChanged: ((Int) -> Void)?
    var onPickImageTapped: (() -> Void)?
    
    // MARK: - UI Components
    lazy var shareTextView: UITextView = {
        let tv = UITextView()
        tv.font = .preferredFont(forTextStyle: .body)
        tv.backgroundColor = tertiarySystemFillColor
        tv.textColor = titleColor
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.isUserInteractionEnabled = true
        tv.isEditable = true
        tv.isSelectable = true
        tv.isScrollEnabled = false // Disable scrolling to allow auto-sizing
        tv.delegate = self
        tv.textContainerInset = UIEdgeInsets(top: textDefaultContainerInset, left: textDefaultContainerInset, bottom: textDefaultContainerInset, right: textDefaultContainerInset)
        return tv
    }()
    
    private var typeButtons: [UIButton] = []
    
    lazy var buttonStackView: UIStackView = {
        let stackView = UIStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.distribution = .fillEqually
        stackView.spacing = 8
        
        for (index, cardType) in CardType.allCases.enumerated() {
            let button = UIButton(type: .system)
            button.setTitle(cardType.description, for: .normal)
            button.tag = index
            button.addTarget(self, action: #selector(handleCardTypeButtonTapped(_:)), for: .touchUpInside)
            button.layer.cornerRadius = 8
            button.backgroundColor = secondarySystemFillColor
            button.setTitleColor(titleColor, for: .normal)
            typeButtons.append(button)
            stackView.addArrangedSubview(button)
        }
        
        return stackView
    }()
    
    lazy var optionsTextView: UITextView = {
        let tv = UITextView()
        tv.font = .preferredFont(forTextStyle: .body)
        tv.backgroundColor = tertiarySystemFillColor
        tv.textColor = titleColor
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.text = "[\"选项1\", \"选项2\", \"选项3\"]" // Placeholder
        return tv
    }()
    
    lazy var correctAnswerTextField: UITextField = {
        let tf = UITextField()
        tf.font = .preferredFont(forTextStyle: .body)
        tf.backgroundColor = tertiarySystemFillColor
        tf.textColor = titleColor
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.placeholder = "例如: 0"
        tf.keyboardType = .numberPad
        return tf
    }()
    
    lazy var pickImageButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("选择图片", for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(handlePickImageTap), for: .touchUpInside)
        return button
    }()
    
    lazy var previewImageView: UIImageView = {
        let iv = UIImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.contentMode = .scaleAspectFit
        iv.isHidden = true
        return iv
    }()
    
    override init(style: UITableViewCell.CellStyle,
                  reuseIdentifier: String?)
    {
        super.init(style: style,
                   reuseIdentifier: reuseIdentifier)
        setupUI()
    }
    
    // MARK: - Actions
    @objc private func handleCardTypeButtonTapped(_ sender: UIButton) {
        onCardTypeChanged?(sender.tag)
    }
    
    @objc private func handlePickImageTap() {
        onPickImageTapped?()
    }
    
    required init?(coder: NSCoder)
    {
        super.init(coder: coder)
    }
    
    override func prepareForReuse()
    {
        super.prepareForReuse()
        // Reset all views
        contentView.subviews.forEach { $0.removeFromSuperview() }
        textLabel?.text = ""
        setupUI()
    }
    
    private func setupUI()
    {
        textLabel?.textAlignment = .center
        textLabel?.textColor = titleColor
        backgroundColor = tableViewBGColor
    }
    
    // Add a placeholder label
    lazy var placeholderLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = placeholderColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.isUserInteractionEnabled = false
        return label
    }()

    func updateConfig(cellType: ImSubmitCellType,
                      model: ImSubmitConfigureProtocol,
                      cardType: CardType,
                      isEditMode: Bool = false)
    {
        // Clean up view before configuring
        contentView.subviews.forEach { $0.removeFromSuperview() }
        
        switch cellType {
        case .input, .inputTitle:
            contentView.addSubview(shareTextView)
            contentView.addSubview(placeholderLabel)
            
            shareTextView.anchor(top: contentView.topAnchor, left: contentView.leftAnchor, bottom: contentView.bottomAnchor, right: contentView.rightAnchor)
            
            // Layout placeholder inside the text view
            NSLayoutConstraint.activate([
                placeholderLabel.topAnchor.constraint(equalTo: shareTextView.topAnchor, constant: textDefaultContainerInset),
                placeholderLabel.leadingAnchor.constraint(equalTo: shareTextView.leadingAnchor, constant: textDefaultContainerInset + 5),
                placeholderLabel.trailingAnchor.constraint(equalTo: shareTextView.trailingAnchor, constant: -(textDefaultContainerInset + 5)),
            ])

            if cellType == .inputTitle {
                shareTextView.text = model.submitQuestion
                placeholderLabel.text = "请输入标题..."
            } else { // .input
                shareTextView.text = model.submitAnswer
                if cardType == .multipleChoice {
                    placeholderLabel.text = """
                    格式如下：
                    # 历史：唐朝的开国皇帝是谁？
                    - 李世民
                    * 李渊 (*为正确)
                    - 李白
                    - 武则天
                    """
                } else {
                    placeholderLabel.text = "请输入答案..."
                }
            }
            // Show/hide placeholder based on text view content
            placeholderLabel.isHidden = !shareTextView.text.isEmpty
            
        case .selectCardType:
            contentView.addSubview(buttonStackView)
            buttonStackView.anchor(top: contentView.safeAreaLayoutGuide.topAnchor,
                                   left: contentView.safeAreaLayoutGuide.leftAnchor,
                                   bottom: contentView.safeAreaLayoutGuide.bottomAnchor,
                                   right: contentView.safeAreaLayoutGuide.rightAnchor,
                                   paddingTop: 8, paddingLeft: 16, paddingBottom: 8, paddingRight: 16)

            // Use the passed-in `cardType` which reflects the latest state, instead of the model's value.
            let selectedIndex = CardType.allCases.firstIndex(of: cardType) ?? 0
            for (index, button) in typeButtons.enumerated() {
                button.backgroundColor = (index == selectedIndex) ? funBtnColor : subTitleColor
                button.isEnabled = !isEditMode
                button.alpha = isEditMode ? 0.5 : 1.0
            }

        case .multipleChoiceOptions:
            contentView.addSubview(optionsTextView)
            optionsTextView.anchor(top: contentView.topAnchor, left: contentView.leftAnchor, bottom: contentView.bottomAnchor, right: contentView.rightAnchor)
            if let cardModel = model as? ImCardModel {
                optionsTextView.text = cardModel.choices ?? "[\"选项1\", \"选项2\"]"
            }
            
        case .multipleChoiceCorrectAnswer:
            contentView.addSubview(correctAnswerTextField)
            correctAnswerTextField.anchor(top: contentView.topAnchor, left: contentView.leftAnchor, bottom: contentView.bottomAnchor, right: contentView.rightAnchor, paddingLeft: 16)
            if let cardModel = model as? ImCardModel, let indices = cardModel.correctAnswerIndices {
                correctAnswerTextField.text = indices
            }
            
        case .imagePicker:
            contentView.addSubview(pickImageButton)
            contentView.addSubview(previewImageView)

            if let cardModel = model as? ImCardModel, let data = cardModel.imageData, let image = UIImage(data: data) {
                previewImageView.image = image
                previewImageView.isHidden = false
                pickImageButton.anchor(top: contentView.topAnchor, left: contentView.leftAnchor, right: contentView.rightAnchor, paddingTop: 8, paddingLeft: 16, paddingRight: 16)
                previewImageView.anchor(top: pickImageButton.bottomAnchor, left: contentView.leftAnchor, bottom: contentView.bottomAnchor, right: contentView.rightAnchor, paddingTop: 8, paddingLeft: 16, paddingBottom: 8, paddingRight: 16)

                // Add height constraint
                let heightConstraint = previewImageView.heightAnchor.constraint(lessThanOrEqualToConstant: UIScreen.main.bounds.height / 2)
                heightConstraint.priority = .defaultHigh
                heightConstraint.isActive = true
            } else {
                previewImageView.isHidden = true
                pickImageButton.anchor(top: contentView.topAnchor, left: contentView.leftAnchor, bottom: contentView.bottomAnchor, right: contentView.rightAnchor, paddingTop: 8, paddingLeft: 16, paddingBottom: 8, paddingRight: 16)
            }

        default:
            textLabel?.text = cellType.rawValue
            backgroundColor = funBtnColor
        }
    }

    override func setSelected(_ selected: Bool,
                              animated: Bool)
    {
        super.setSelected(selected,
                          animated: animated)
    }
    
    // MARK: - UITextViewDelegate
    func textViewDidChange(_ textView: UITextView) {
        delegate?.textViewDidChange(cell: self)
        // Hide placeholder when user starts typing
        if textView == shareTextView {
            placeholderLabel.isHidden = !textView.text.isEmpty
        }
    }
}
