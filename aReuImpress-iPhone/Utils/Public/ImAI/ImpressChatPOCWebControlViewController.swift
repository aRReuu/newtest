#if DEBUG
import UIKit
import WebKit
import ImpressReviewCore

/// POC-05 experimental control: ONE offline WKWebView parses the same SSE
/// fixture end-to-end. It is not a substitute for native message containers,
/// local persistence, approval gates, or provider consent.
@MainActor
final class ImpressChatPOCWebControlViewController: UIViewController, WKNavigationDelegate {
    private let html: WKWebView
    private let report = UILabel()
    private let frames: [Data]
    private var replayTask: Task<Void, Never>?
    private var replayText = ""
    private var webReady = false
    private var rendering = false
    private var pendingRender = false
    private var renderCount = 0
    private var cumulativeRenderMS = 0.0
    private var largestRenderMS = 0.0
    private var terminal = "准备中"

    init(frames: [Data]) {
        self.frames = frames
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        html = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(frames:) required") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Markdown A/B · 离线 Web 对照"
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemBackground
        report.numberOfLines = 0
        report.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        report.textColor = .secondaryLabel
        report.accessibilityIdentifier = "impress.chat.poc.web-report"
        report.text = "同一合成 SSE → 单 WKWebView → 整体 Markdown 重解析"
        report.translatesAutoresizingMaskIntoConstraints = false
        html.translatesAutoresizingMaskIntoConstraints = false
        html.isOpaque = false
        html.backgroundColor = .systemBackground
        html.scrollView.backgroundColor = .systemBackground
        html.navigationDelegate = self
        html.accessibilityIdentifier = "impress.chat.poc.single-web-control"
        view.addSubview(report)
        view.addSubview(html)
        NSLayoutConstraint.activate([
            report.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                                            constant: 14),
            report.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                                             constant: -14),
            report.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            html.topAnchor.constraint(equalTo: report.bottomAnchor, constant: 12),
            html.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            html.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            html.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        guard let resource = Bundle.main.url(forResource: "index", withExtension: "html",
                                             subdirectory: "MarkdownReader") else {
            terminal = "缺少离线 MarkdownReader 资源"
            displayMetrics()
            return
        }
        html.loadFileURL(resource, allowingReadAccessTo: resource.deletingLastPathComponent())
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || isBeingDismissed {
            replayTask?.cancel()
            replayTask = nil
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !webReady else { return }
        webReady = true
        terminal = "流式回放中"
        displayMetrics()
        replayTask = Task { [weak self] in
            guard let self else { return }
            var reader = ImpressChatPOCReplay(provider: .openAIChat)
            do {
                for fragment in self.frames {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 22_000_000)
                    for event in try reader.append(fragment) {
                        switch event {
                        case .delta(let text):
                            self.replayText += text
                            self.scheduleRender()
                        case .completed:
                            self.terminal = "明确结束"
                            self.scheduleRender()
                            self.displayMetrics()
                            return
                        case .failed:
                            self.terminal = "失败：不接受不完整输出"
                            self.scheduleRender()
                            self.displayMetrics()
                            return
                        }
                    }
                }
                for event in try reader.finish() {
                    switch event {
                    case .delta(let text): self.replayText += text
                    case .completed: self.terminal = "明确结束"
                    case .failed: self.terminal = "失败"
                    }
                }
                if !reader.normalizer.isCompleted { self.terminal = "意外 EOF · 非完成" }
                self.scheduleRender()
                self.displayMetrics()
            } catch is CancellationError {
                self.terminal = "手动关闭对照"
            } catch {
                self.terminal = "事件协议校验失败"
            }
            self.displayMetrics()
        }
    }

    private func scheduleRender() {
        guard webReady else { return }
        if rendering { pendingRender = true; return }
        rendering = true
        let body = replayText
        let startedAt = CFAbsoluteTimeGetCurrent()
        guard let json = try? JSONSerialization.data(withJSONObject: [body]),
              let serialized = String(data: json, encoding: .utf8) else {
            rendering = false
            return
        }
        // Never interpolate unescaped Markdown into executable JavaScript.
        let script = "window.renderImpressMarkdown(" + serialized +
            "[0], { documentTitle:'', properties: [], fontSize:17, css:'' })"
        html.evaluateJavaScript(script) { [weak self] _, error in
            guard let self else { return }
            self.rendering = false
            let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
            self.renderCount += 1
            self.cumulativeRenderMS += ms
            self.largestRenderMS = max(self.largestRenderMS, ms)
            if error != nil { self.terminal = "WK JS 渲染失败" }
            self.displayMetrics()
            if self.pendingRender {
                self.pendingRender = false
                self.scheduleRender()
            }
        }
    }

    private func displayMetrics() {
        let average = renderCount == 0 ? 0 : cumulativeRenderMS / Double(renderCount)
        report.text = "实验对照（非最终架构） | 状态：" + terminal + "\n" +
            "可见文本 " + String(replayText.utf8.count) + " bytes · 全页解析 " +
            String(renderCount) + " 次\n" +
            String(format: "WK 平均 %.1f ms · 最慢 %.1f ms（非 FPS）",
                   average, largestRenderMS)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        decisionHandler(scheme == "file" ? .allow : .cancel)
    }
}
#endif
