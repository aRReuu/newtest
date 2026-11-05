//
//  ImImageCardView.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 2025/10/1.
//

import UIKit

class ImImageCardView: UIView {
    
    private let questionLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.preferredFont(forTextStyle: .title3)
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()
    
    private let answerImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.isHidden = true
        return imageView
    }()
    
    private let tapGestureRecognizer = UITapGestureRecognizer()
    
    init(model: ImCardModel) {
        super.init(frame: .zero)
        setupViews()
        configure(with: model)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupViews() {
        addSubview(questionLabel)
        addSubview(answerImageView)
        
        NSLayoutConstraint.activate([
            questionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            questionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            questionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: defaultSpacing),
            questionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -defaultSpacing),
            
            answerImageView.topAnchor.constraint(equalTo: topAnchor),
            answerImageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            answerImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            answerImageView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        
        tapGestureRecognizer.addTarget(self, action: #selector(viewTapped))
        addGestureRecognizer(tapGestureRecognizer)
    }
    
    func configure(with model: ImCardModel) {
        questionLabel.text = model.question
        if let imageData = model.imageData {
            answerImageView.image = UIImage(data: imageData)
        }
    }
    
    @objc private func viewTapped() {
        let isAnswerHidden = answerImageView.isHidden
        
        UIView.transition(with: self, duration: 0.3, options: .transitionFlipFromRight, animations: {
            self.questionLabel.isHidden = isAnswerHidden
            self.answerImageView.isHidden = !isAnswerHidden
        }, completion: nil)
    }
}
