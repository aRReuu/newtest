import UIKit
import WebKit
import ImpressReviewCore

/// Native, selectable, horizontally scrollable renderer for code and tables.
/// Provisional GFM tables remain selectable raw text until syntactically stable.
@MainActor
final class ImpressChatPOCStructuredCell: UICollectionViewCell {
    private let shell = UIView()
    private let stack = UIStackView()
    private let heading = UILabel()
    private let copy = UIButton(type: .system)
    private let scroller = UIScrollView()
    private var heightConstraint: NSLayoutConstraint?
    private var renderedContent: UIView?
    private var source = ""
    private var sourceKind: ImpressChatPOCBlock.Kind = .paragraph

    override init(frame: CGRect) {
        super.init(frame: frame)
        shell.backgroundColor = .secondarySystemBackground
        shell.layer.cornerRadius = 12
        shell.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 0
        heading.font = .preferredFont(forTextStyle: .caption1)
        heading.adjustsFontForContentSizeCategory = true
        heading.textColor = .secondaryLabel
        copy.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
        copy.accessibilityLabel = "复制原始内容"
        copy.accessibilityIdentifier = "impress.chat.poc.content-copy"
        copy.addTarget(self, action: #selector(copyRaw), for: .touchUpInside)
        copy.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        copy.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let bar = UIStackView(arrangedSubviews: [heading, copy])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.layoutMargins = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 3)
        bar.isLayoutMarginsRelativeArrangement = true
        stack.addArrangedSubview(bar)
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.showsHorizontalScrollIndicator = true
        scroller.showsVerticalScrollIndicator = false
        scroller.alwaysBounceHorizontal = true
        scroller.isDirectionalLockEnabled = true
        stack.addArrangedSubview(scroller)
        contentView.addSubview(shell)
        shell.addSubview(stack)
        NSLayoutConstraint.activate([
            shell.topAnchor.constraint(equalTo: contentView.topAnchor),
            shell.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            shell.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: shell.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: shell.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: shell.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: shell.trailingAnchor)
        ])
        let height = scroller.heightAnchor.constraint(equalToConstant: 80)
        height.isActive = true
        heightConstraint = height
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    func configure(markdown: String, kind: ImpressChatPOCBlock.Kind, stable: Bool) {
        source = markdown
        sourceKind = kind
        heading.text = kind == .code ? codeLanguage(markdown) :
            (stable ? "表格" : "表格 · 生成中")
        renderedContent?.removeFromSuperview()
        renderedContent = nil
        scroller.setContentOffset(.zero, animated: false)
        switch kind {
        case .table where stable:
            let cells = tableRows(markdown)
            if !cells.isEmpty && cells.count <= 140 &&
               (cells.map(\.count).max() ?? 0) <= 16 {
                showTable(cells)
                return
            }
            showCode(markdown, language: nil)
        default:
            showCode(markdown, language: kind == .code ? codeLanguage(markdown) : nil)
        }
        accessibilityIdentifier = kind == .table ?
            "impress.chat.poc.table" : "impress.chat.poc.code"
    }

    private func openingCodeFence(_ raw: String)
        -> (marker: Character, count: Int, language: String)? {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard let first = normalized.split(separator: "\n",
                    omittingEmptySubsequences: false).first else { return nil }
        let indentation = first.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return nil }
        let body = first.dropFirst(indentation)
        guard let marker = body.first, marker == "~" || marker == "\u{60}"
        else { return nil }
        let count = body.prefix(while: { $0 == marker }).count
        guard count >= 3 else { return nil }
        let language = body.dropFirst(count).trimmingCharacters(
            in: .whitespacesAndNewlines)
        return (marker, count, String(language.prefix(28)))
    }

    private func codeLanguage(_ raw: String) -> String {
        guard let fence = openingCodeFence(raw), !fence.language.isEmpty
        else { return "代码" }
        return fence.language
    }

    private func codeBody(_ text: String) -> String {
        // Treat the opening run length and delimiter kind as authoritative.
        // A four-tilde block cannot close with three tildes or backticks.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2, let fence = openingCodeFence(normalized),
              let last = lines.last else { return text }
        let indentation = last.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return text }
        let closing = last.dropFirst(indentation)
        let run = closing.prefix(while: { $0 == fence.marker }).count
        guard run >= fence.count,
              closing.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" })
        else { return text }
        return lines.dropFirst().dropLast().joined(separator: "\n")
    }

    private func showCode(_ raw: String, language: String?) {
        let body = language == nil ? raw : codeBody(raw)
        let font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize - 2,
            weight: .regular)
        // Native TextKit selection remains available inside horizontal code.
        let label = UITextView()
        label.font = font
        label.isEditable = false
        label.isSelectable = true
        label.isScrollEnabled = false
        label.textContainerInset = .zero
        label.textContainer.lineFragmentPadding = 0
        label.textContainer.lineBreakMode = .byClipping
        label.backgroundColor = .clear
        label.accessibilityLabel = body
        label.attributedText = highlight(body, font: font)
        label.translatesAutoresizingMaskIntoConstraints = false
        let lines = body.components(separatedBy: "\n")
        let maxLine = lines.max(by: { $0.utf16.count < $1.utf16.count }) ?? ""
        let width = max(180, min(6_000,
            (maxLine as NSString).size(withAttributes: [.font: font]).width + 38))
        let fullHeight = CGFloat(lines.count) * font.lineHeight + 28
        heightConstraint?.constant = min(760, max(52, fullHeight))
        scroller.showsVerticalScrollIndicator = fullHeight > 760
        scroller.alwaysBounceVertical = fullHeight > 760
        scroller.addSubview(label)
        renderedContent = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor,
                                           constant: 12),
            label.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor,
                                            constant: -12),
            label.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor,
                                          constant: -8),
            label.widthAnchor.constraint(equalToConstant: width),
            label.heightAnchor.constraint(greaterThanOrEqualToConstant: max(36, fullHeight - 16))
        ])
    }

    private func highlight(_ source: String, font: UIFont) -> NSAttributedString {
        let output = NSMutableAttributedString(string: source, attributes: [
            .font: font, .foregroundColor: UIColor.label
        ])
        guard source.utf8.count <= 96_000,
              let regex = try? NSRegularExpression(
                pattern: #"(?m)//[^\n]*|"(?:\\.|[^"\\])*"|\b(?:let|var|func|if|else|guard|return|struct|class|import|enum|case|async|await|try|throw)\b"#)
        else { return output }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in regex.matches(in: source, range: range) {
            let part = (source as NSString).substring(with: match.range)
            let ink: UIColor = part.hasPrefix("//") ? .systemGreen :
                                part.hasPrefix("\"") ? .systemOrange : .systemBlue
            output.addAttribute(.foregroundColor, value: ink, range: match.range)
        }
        return output
    }

    private func tableRows(_ source: String) -> [[String]] {
        let visible = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = visible.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2 else { return [] }
        var rows = [[String]]()
        for (index, raw) in lines.enumerated() {
            var columns = [String](), current = "", escape = false
            for char in raw {
                if escape {
                    // Only escaped pipes or backslashes consume the slash.
                    if char != "|" && char != "\\" { current.append("\\") }
                    current.append(char)
                    escape = false
                    continue
                }
                if char == "\\" { escape = true; continue }
                if char == "|" { columns.append(current); current = "" }
                else { current.append(char) }
            }
            if escape { current.append("\\") }
            columns.append(current)
            if raw.first == "|", !columns.isEmpty { columns.removeFirst() }
            if raw.last == "|", !columns.isEmpty { columns.removeLast() }
            let trimmed = columns.map { $0.trimmingCharacters(in: .whitespaces) }
            if index == 1 && trimmed.allSatisfy({ cell in
                cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
            }) { continue }
            rows.append(trimmed)
        }
        let count = rows.map(\.count).max() ?? 0
        return rows.map { $0 + Array(repeating: "", count: max(0, count - $0.count)) }
    }

    private func showTable(_ rows: [[String]]) {
        guard let count = rows.first?.count, count > 0 else { showCode(source, language: nil); return }
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let widths: [CGFloat] = (0..<count).map { column in
            let longest = rows.map { $0[column] }.max(by: { $0.count < $1.count }) ?? ""
            return max(96, min(260,
                (longest as NSString).size(withAttributes: [.font: font]).width + 28))
        }
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 0
        grid.translatesAutoresizingMaskIntoConstraints = false
        var projectedHeight: CGFloat = 0
        for (i, values) in rows.enumerated() {
            let row = UIStackView()
            row.axis = .horizontal
            row.alignment = .fill
            row.spacing = 1
            var rowHeight: CGFloat = 40
            for j in values.indices {
                let label = UILabel()
                label.text = values[j]
                label.font = i == 0 ?
                    UIFont.preferredFont(forTextStyle: .headline) : font
                label.numberOfLines = 0
                label.adjustsFontForContentSizeCategory = true
                label.textColor = .label
                label.backgroundColor = i == 0 ? .tertiarySystemFill :
                    (i % 2 == 0 ? UIColor.systemBackground : UIColor.secondarySystemBackground)
                label.accessibilityLabel = values[j]
                label.textAlignment = .left
                label.widthAnchor.constraint(equalToConstant: widths[j]).isActive = true
                // A single long cell can exceed three lines even when there
                // are very few table rows. Measure its actual wrapped height.
                let glyphHeight = label.sizeThatFits(CGSize(
                    width: widths[j], height: .greatestFiniteMagnitude)).height
                rowHeight = max(rowHeight, ceil(glyphHeight) + 12)
                row.addArrangedSubview(label)
            }
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: rowHeight)
                .isActive = true
            projectedHeight += rowHeight
            grid.addArrangedSubview(row)
        }
        let needsVerticalScroll = projectedHeight + 2 > 530
        scroller.showsVerticalScrollIndicator = needsVerticalScroll
        scroller.alwaysBounceVertical = needsVerticalScroll
        heightConstraint?.constant = min(530, max(40, projectedHeight + 2))
        scroller.addSubview(grid)
        renderedContent = grid
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor,
                                          constant: 10),
            grid.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor,
                                           constant: -10),
            grid.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            grid.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            grid.widthAnchor.constraint(equalToConstant: widths.reduce(0, +) + CGFloat(count-1))
        ])
        accessibilityIdentifier = "impress.chat.poc.table"
    }

    @objc private func copyRaw() {
        UIPasteboard.general.string = sourceKind == .code ? codeBody(source) : source
    }
}

/// A distinct offline KaTeX experiment. It never executes a remote script or
/// accesses the Vault. WK is used only for formulas, not the message/scroll UI.
@MainActor
final class ImpressChatPOCMathCell: UICollectionViewCell, WKNavigationDelegate {
    private let header = UIStackView()
    private let label = UILabel()
    private let copy = UIButton(type: .system)
    private let fallback = UILabel()
    private let fallbackCover = UIView()
    private let web: WKWebView
    private var ready = false
    private var current = ""
    private var renderEpoch = 0
    private var sourceIsStable = false

    override init(frame: CGRect) {
        let settings = WKWebViewConfiguration()
        settings.defaultWebpagePreferences.allowsContentJavaScript = true
        web = WKWebView(frame: .zero, configuration: settings)
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true
        header.axis = .horizontal
        header.alignment = .center
        header.layoutMargins = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 4)
        header.isLayoutMarginsRelativeArrangement = true
        label.text = "KaTeX · 离线"
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        copy.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
        copy.accessibilityLabel = "复制 LaTeX"
        copy.accessibilityIdentifier = "impress.chat.poc.math-copy"
        copy.addTarget(self, action: #selector(copySource), for: .touchUpInside)
        copy.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        copy.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        header.addArrangedSubview(label)
        header.addArrangedSubview(copy)
        fallback.numberOfLines = 0
        fallback.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        fallback.textColor = .label
        fallback.translatesAutoresizingMaskIntoConstraints = false
        fallbackCover.translatesAutoresizingMaskIntoConstraints = false
        fallbackCover.backgroundColor = .secondarySystemBackground
        fallbackCover.accessibilityIdentifier = "impress.chat.poc.math-fallback-cover"
        fallbackCover.isUserInteractionEnabled = false
        web.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.navigationDelegate = self
        web.accessibilityIdentifier = "impress.chat.poc.math-katex"
        // Hidden WKWebViews may defer loading in headless Simulator tests.
        // Keep it attached, while an opaque overlay hides any unverified HTML.
        web.isHidden = false
        contentView.addSubview(header)
        contentView.addSubview(web)
        contentView.addSubview(fallbackCover)
        fallbackCover.addSubview(fallback)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            header.topAnchor.constraint(equalTo: contentView.topAnchor),
            web.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            web.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            web.topAnchor.constraint(equalTo: header.bottomAnchor),
            web.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            web.heightAnchor.constraint(equalToConstant: 128),
            fallbackCover.leadingAnchor.constraint(equalTo: web.leadingAnchor),
            fallbackCover.trailingAnchor.constraint(equalTo: web.trailingAnchor),
            fallbackCover.topAnchor.constraint(equalTo: web.topAnchor),
            fallbackCover.bottomAnchor.constraint(equalTo: web.bottomAnchor),
            fallback.leadingAnchor.constraint(equalTo: fallbackCover.leadingAnchor, constant: 4),
            fallback.trailingAnchor.constraint(equalTo: fallbackCover.trailingAnchor, constant: -4),
            fallback.centerYAnchor.constraint(equalTo: fallbackCover.centerYAnchor)
        ])
        if let directory = Bundle.main.url(forResource: "index", withExtension: "html",
                                           subdirectory: "MarkdownReader") {
            web.loadFileURL(directory, allowingReadAccessTo: directory.deletingLastPathComponent())
        } else {
            fallback.text = "KaTeX 离线资源不可用"
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    func configure(_ source: String, stable: Bool) {
        current = source
        sourceIsStable = stable
        renderEpoch &+= 1
        fallback.text = source
        fallback.isHidden = false
        fallbackCover.isHidden = false
        accessibilityLabel = "公式：" + source
        if stable && ready { render() }
    }

    private func render() {
        guard ready, sourceIsStable, current.utf8.count <= 10_000 else { return }
        let epoch = renderEpoch
        let css = "#reader{min-height:0!important;padding:4px!important}" +
                  ".im-document-header{display:none!important}" +
                  ".markdown-body{background:transparent!important}" +
                  ".katex-display{margin:0!important}"
        // The reader returns a Promise. An error-free JavaScript invocation
        // is not proof of KaTeX rendering; wait for its actual DOM result.
        // Typed arguments prevent Markdown text from becoming executable JS.
        let javascript = """
            await window.renderImpressMarkdown(markdown, {
                css: css, documentTitle: '', fontSize: 18, properties: []
            });
            return document.querySelectorAll('.katex').length;
            """
        // iOS 26+ exposes this as an async throws API rather than the old
        // completion-handler overload. Each render is tied to the reuse epoch.
        Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await self.web.callAsyncJavaScript(javascript,
                    arguments: ["markdown": current, "css": css],
                    in: nil, contentWorld: .page)
                guard self.renderEpoch == epoch,
                      let renderedCount = value as? NSNumber,
                      renderedCount.intValue > 0 else { return }
                self.fallback.isHidden = true
                self.fallbackCover.isHidden = true
            } catch {
                // Preserve the selectable TeX fallback; no false render PASS.
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        render()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Even if an offline document includes a link, the POC must not navigate.
        decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
    }
    @objc private func copySource() { UIPasteboard.general.string = current }
}
