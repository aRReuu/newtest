//
//  ImExtractTextView.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 12/10/24.
//

import UIKit

class ImExtractTextView: UITextView, UITextViewDelegate
{
    /// Markdown渲染器
    private let markdownRenderer = MarkdownKitRenderer()

    /// 文本摘录回调 - 只传递选中文本，业务逻辑完全交给外部处理
    var onTextExtracted: ((String) -> Void)?

    override var text: String! {
        didSet {
//            applyMarkdownStyles()
        }
    }
    
    // Retain native iOS text selection/copy/Look Up/Translate without
    // registering the old global UIMenuController "摘录" item.
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        initUISetting()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        initUISetting()
    }

    private func initUISetting() {
        self.font = UIFont.preferredFont(forTextStyle: .body)
        self.textColor = contentColor
        self.textAlignment = .center
        self.textContainerInset = UIEdgeInsets.init(top: textDefaultContainerInset,
                                                    left: textDefaultContainerInset,
                                                    bottom: textDefaultContainerInset,
                                                    right: textDefaultContainerInset)
    }
    
    func textView(_ textView: UITextView,
                  shouldInteractWith URL: URL,
                  in characterRange: NSRange,
                  interaction: UITextItemInteraction) -> Bool {
        return false
    }
    
    

}



// MARK:  - Markdown渲染
extension ImExtractTextView
{
    private func applyMarkdownStyles()
    {
        guard let text = self.text, !text.isEmpty else { return }
        if let attributedText = markdownRenderer.parseMarkdown(text) {
            self.attributedText = attributedText
        }
    }
}
