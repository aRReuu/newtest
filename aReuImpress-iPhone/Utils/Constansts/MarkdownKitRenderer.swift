import UIKit
import MarkdownKit

final class MarkdownKitRenderer {

    /// MarkdownKit解析器实例
    var parser: MarkdownParser!

    /// 基础字体
    private let bodyFont = UIFont.preferredFont(forTextStyle: .headline)

    
    init()
    {
        self.configureBasicStyles()
    }

    /// 配置基础的Markdown样式
    private func configureBasicStyles()
    {
        parser = MarkdownParser(font:bodyFont,color: contentColor)

        // 标题样式
        parser.header.font = UIFont.boldSystemFont(ofSize: bodyFont.pointSize + 2)
        parser.header.color = contentColor
        parser.header.fontIncrease = 2  // 标题字体增量

        // 粗体样式
        parser.bold.font = UIFont.boldSystemFont(ofSize: bodyFont.pointSize)
        parser.bold.color = titleColor

        // 斜体样式
        parser.italic.font = UIFont.italicSystemFont(ofSize: bodyFont.pointSize)
        parser.italic.color = contentColor

        // 代码块样式
        parser.code.font = UIFont.monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .regular)
        parser.code.color = subTitleColor
        parser.code.textHighlightColor = safeTipColor
        parser.code.textBackgroundColor = tableViewBGColor

        // 链接样式
        parser.link.font = bodyFont
        parser.link.color = funBtnColor

        // 引用样式
        parser.quote.font = bodyFont
        parser.quote.color = highlightColor

        // 列表样式
        parser.list.font = bodyFont
        parser.list.color = contentColor

        // 删除线样式
        parser.strikethrough.font = bodyFont
        parser.strikethrough.color = subTitleColor

        parser.enabledElements = .all
    }

    /// 将Markdown字符串解析为富文本
    /// - Parameter markdownText: Markdown格式的文本
    /// - Returns: 富文本字符串，如果解析失败返回nil
    func parseMarkdown(_ markdownText: String) -> NSAttributedString? {
        return parser.parse(markdownText)
    }
}
