//
//  ImCardListCell.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 11/1/24.
//

import UIKit

/// 卡片列表单元格
class ImCardListCell: UITableViewCell {
    static let reuseIdentifier = "ImCardListCell"

    // MARK: - UI Components
    private let cardTypeIcon: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = funBtnColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()

    private let questionLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .headline)
        label.textColor = titleColor
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let answerLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.textColor = contentColor
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let stackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let containerStackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()
    
    // MARK: - Initialization
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Setup
    private func setupViews() {
        selectionStyle = .default
        // 添加图标到容器堆栈视图
        containerStackView.addArrangedSubview(cardTypeIcon)
        containerStackView.addArrangedSubview(stackView)

        contentView.addSubview(containerStackView)
        stackView.addArrangedSubview(questionLabel)
        stackView.addArrangedSubview(answerLabel)

        NSLayoutConstraint.activate([
            // 图标尺寸约束
            cardTypeIcon.widthAnchor.constraint(equalToConstant: 24),
            cardTypeIcon.heightAnchor.constraint(equalToConstant: 24),

            // 容器堆栈视图约束
            containerStackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: defaultSpacing),
            containerStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: defaultSpacing),
            containerStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -defaultSpacing),
            containerStackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -defaultSpacing)
        ])
    }
    
    // MARK: - Configuration
    func configure(with card: ImCardModel) {
        questionLabel.text = card.question ?? "无问题"
        answerLabel.text = card.answer ?? "无答案"

        // 根据卡片类型显示不同图标
        let cardType = CardType(rawValue: card.cardType ?? 0) ?? .standard
        switch cardType {
        case .standard:
            cardTypeIcon.image = UIImage(systemName: "rectangle")
            cardTypeIcon.tintColor = funBtnColor
        case .multipleChoice:
            cardTypeIcon.image = UIImage(systemName: "checkmark.circle")
            cardTypeIcon.tintColor = safeTipColor
        case .image:
            cardTypeIcon.image = UIImage(systemName: "photo")
            cardTypeIcon.tintColor = highlightColor
        }

        cardTypeIcon.isHidden = false
    }
    
    // MARK: - Reuse
    override func prepareForReuse() {
        super.prepareForReuse()
        questionLabel.text = nil
        answerLabel.text = nil
    }
}
