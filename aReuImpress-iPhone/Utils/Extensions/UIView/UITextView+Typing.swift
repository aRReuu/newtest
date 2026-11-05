import UIKit
import MarkdownKit

extension UITextView
{
    // MARK: - MarkdownKit渲染器单例
    private static let markdownRenderer: MarkdownKitRenderer = MarkdownKitRenderer()

    /// 直接设置并显示 Markdown 文本，无动画效果。
    /// - Parameter markdownText: 要显示的 Markdown 字符串。
    func setMarkdownText(_ markdownText: String) {
        // 使用MarkdownKitRenderer进行基础解析
        if let attributedText = UITextView.markdownRenderer.parseMarkdown(markdownText) {
            self.attributedText = attributedText
        } else {
            // 如果解析失败，直接显示原始文本
            print("MarkdownKit Markdown parsing failed")
            self.text = markdownText
        }
    }
}
