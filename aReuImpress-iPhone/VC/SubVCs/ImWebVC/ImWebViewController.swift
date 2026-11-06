//
//  ImWebViewController.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 1/15/26.
//

import UIKit
import WebKit
import Combine

/// Preparing a handoff does not send it to DeepSeek. The user explicitly
/// inserts the material into the React editor and separately triggers Send.
enum ImpressV3DeepSeekHandoff {
    static func makePayload(question: String,
                            answer: String?,
                            userPrompt: String?) -> String {
        let custom = userPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let learningStyle = (custom?.isEmpty == false)
            ? custom!
            : "采用第一性原理和奥卡姆剃刀，辨别假设与证据，只保留必要的解释。"
        let reference = answer?.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        [学习方式]
        \(learningStyle)

        [当前卡片]
        问题：\(question)
        参考答案：\((reference?.isEmpty == false) ? reference! : "当前卡片没有可用的文字答案。")

        [本次请求]
        请帮助我检验理解中的假设、因果与遗漏，通过必要的追问引导我自主推导。不要直接假定参考答案正确。
        """
    }

    static func makeNotePayload(title: String, markdown: String?,
                                userPrompt: String?) -> String {
        let custom = userPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let learningStyle = custom?.isEmpty == false ? custom!
            : "采用第一性原理和奥卡姆剃刀，辨别假设与证据，只保留必要的解释。"
        let material = markdown ?? "正文超过本次授权的 8 KB 限额，仅提供标题。请在笔记内明确选择片段后再提交。"
        return """
        [学习方式]
        \(learningStyle)

        [来源笔记]
        \(title)
        \(material)

        [本次请求]
        请围绕以上已选择的笔记内容，协助核查观点、理解与遗漏，不要假定原文结论必然正确。
        """
    }
}


/// DeepSeek's editor is a React-controlled page, not a URL-parameter API.
/// All DOM operations happen in the page's JavaScript world, following a
/// deliberate native action. A successful write never implies a network send.
enum ImpressV3DeepSeekDOMBridge {
    static let insert = #"""
    if (location.protocol !== "https:" || location.hostname !== "chat.deepseek.com") {
        return {ok: false, reason: "untrusted_origin"};
    }
    const text = String(payload ?? "");
    if (!text.trim()) return {ok: false, reason: "empty_payload"};
    const visible = el => {
        const r = el.getBoundingClientRect();
        const css = getComputedStyle(el);
        return r.width > 5 && r.height > 5 && css.display !== "none" &&
            css.visibility !== "hidden" && !el.closest('[aria-hidden="true"]');
    };
    const candidates = Array.from(document.querySelectorAll(
        'textarea, [contenteditable="true"], [role="textbox"]'
    )).filter(visible).sort((a, b) =>
        b.getBoundingClientRect().bottom - a.getBoundingClientRect().bottom);
    const input = candidates[0];
    if (!input) return {ok: false, reason: "input_not_found"};
    const isTextArea = input instanceof HTMLTextAreaElement ||
        input instanceof HTMLInputElement;
    const previous = isTextArea ? input.value : (input.innerText || input.textContent || "");
    const next = append === true && previous.trim()
        ? previous.trimEnd() + "\n" + text : text;
    input.focus();
    let nativeEdit = false;
    if (isTextArea) {
        const prototype = input instanceof HTMLTextAreaElement
            ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
        if (!setter) return {ok: false, reason: "native_setter_missing"};
        // Calling the prototype setter rather than input.value = ... avoids
        // React's value tracker swallowing the subsequent input event.
        setter.call(input, next);
        input.dispatchEvent(new InputEvent("input", {
            bubbles: true, inputType: "insertText", data: text
        }));
        input.dispatchEvent(new Event("change", {bubbles: true}));
        nativeEdit = true;
    } else {
        // Rich contenteditables (Quill/ProseMirror/React) must receive an
        // editing transaction; setting innerHTML alone bypasses React state.
        const selection = window.getSelection();
        const range = document.createRange();
        range.selectNodeContents(input);
        selection.removeAllRanges();
        selection.addRange(range);
        nativeEdit = !!document.execCommand?.("insertText", false, next);
        if (!nativeEdit) return {ok: false, reason: "editor_rejected_input"};
    }
    const actual = isTextArea ? input.value : (input.innerText || input.textContent || "");
    return {ok: nativeEdit && actual.trim() === next.trim(),
        reason: actual.trim() === next.trim() ? "inserted" : "input_mismatch"};
    """#

    static let send = #"""
    if (location.protocol !== "https:" || location.hostname !== "chat.deepseek.com") {
        return {ok: false, reason: "untrusted_origin"};
    }
    const visible = el => {
        const r = el.getBoundingClientRect();
        const css = getComputedStyle(el);
        return r.width > 5 && r.height > 5 && css.display !== "none" &&
            css.visibility !== "hidden";
    };
    const editors = Array.from(document.querySelectorAll(
        'textarea, [contenteditable="true"], [role="textbox"]'
    )).filter(visible).sort((a, b) =>
        b.getBoundingClientRect().bottom - a.getBoundingClientRect().bottom);
    const input = editors[0];
    if (!input) return {ok: false, reason: "input_not_found"};
    const value = input instanceof HTMLTextAreaElement || input instanceof HTMLInputElement
        ? input.value : (input.innerText || input.textContent || "");
    if (!value.trim()) return {ok: false, reason: "empty_message"};
    const scopes = [];
    let parent = input;
    for (let n = 0; parent && n < 7; n++, parent = parent.parentElement) {
        scopes.push(parent);
    }
    let sendButton = null;
    for (const scope of scopes) {
        const controls = Array.from(scope.querySelectorAll('button, [role="button"]'))
            .filter(visible);
        sendButton = controls.find(el =>
            /(^|[\s_-])(send|submit)([\s_-]|$)|发送|提交/i.test(
                [el.getAttribute("aria-label"), el.getAttribute("title"),
                 el.getAttribute("data-testid")].filter(Boolean).join(" ")));
        if (!sendButton) sendButton = controls.find(el =>
            el.matches('button[type="submit"]'));
        if (sendButton) break;
    }
    if (!sendButton) return {ok: false, reason: "send_control_not_found"};
    if (sendButton.disabled || sendButton.getAttribute("aria-disabled") === "true") {
        return {ok: false, reason: "send_disabled"};
    }
    sendButton.click();
    return {ok: true, reason: "send_clicked"};
    """#
}

/// WKWebView控制器单例
/// 用于显示DeepSeek聊天页面，并提供生成复习卡片的功能
class ImWebViewController: UIViewController, WKNavigationDelegate {

    // MARK: - Singleton
    static let shared = ImWebViewController()

    // MARK: - Properties
    private var webView = WKWebView()
    private let floatingButton = UIButton(type: .custom)
    private var isDragging = false
    private var initialCenter: CGPoint = .zero
    private var cancellables = Set<AnyCancellable>()
    private var reviewHandoffText: String?
    private var copyHandoffButton: UIBarButtonItem?
    private let viewModel = ImCardViewModel() // 将viewModel作为属性保留

    // MARK: - Initialization
    private init() {
        super.init(nibName: nil, bundle: nil)
    }

    /// Every V3 learning handoff gets a fresh web controller. Legacy singleton
    /// paths remain available until the old business routes are retired.
    static func forReviewHandoff(text: String) -> ImWebViewController {
        let controller = ImWebViewController()
        controller.reviewHandoffText = text
        return controller
    }

    /// Fresh Web route from Settings: no carried question and no old card button.
    static func forDirectBrowse() -> ImWebViewController {
        let controller = ImWebViewController()
        controller.reviewHandoffText = ""
        return controller
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        if reviewHandoffText == nil { bindAction() }
        setupConstraints()
        setupNavigationBar()
        loadInitialURL()
        if reviewHandoffText == nil { setupFloatingButton() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        idleSet(true)
        floatingButton.isHidden = reviewHandoffText != nil
        updatePromptMenu()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        floatingButton.isHidden = true
        idleSet(false)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // 屏幕旋转时重新定位按钮
        if floatingButton.superview != nil {
            let buttonSize = defaultSpacing * 3
            let spacing = defaultSpacing

            // 确保按钮在新的安全区域内
            var newY = view.safeAreaLayoutGuide.layoutFrame.maxY - buttonSize - spacing
            if newY < view.safeAreaInsets.top + buttonSize {
                newY = view.safeAreaInsets.top + spacing + buttonSize
            }

            floatingButton.frame.origin.y = newY

            // 确保水平位置也在安全区域内
            var newX = floatingButton.frame.origin.x
            let minX = view.safeAreaInsets.left + spacing
            let maxX = view.bounds.width - view.safeAreaInsets.right - buttonSize - spacing

            if newX < minX {
                newX = minX
            } else if newX > maxX {
                newX = maxX
            }

            floatingButton.frame.origin.x = newX
        }
    }

    // MARK: - Setup
    private func setupViews() {
        view.backgroundColor = ImpressV3Appearance.page

        // WebView配置
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()

        let newWebView = WKWebView(frame: .zero, configuration: configuration)
        newWebView.navigationDelegate = self
        newWebView.allowsBackForwardNavigationGestures = true
        newWebView.scrollView.showsVerticalScrollIndicator = true
        newWebView.scrollView.showsHorizontalScrollIndicator = false

        view.addSubview(newWebView)
        self.webView = newWebView
    }

    private func setupConstraints() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }

    private func setupNavigationBar() {
        navigationItem.largeTitleDisplayMode = .never
        title = "网页聊天"
        let refresh = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"),
                                      style: .plain, target: self,
                                      action: #selector(refreshPage))
        let close = UIBarButtonItem(image: UIImage(systemName: "xmark"),
                                    style: .plain, target: self,
                                    action: #selector(closeWebView))
        navigationItem.leftBarButtonItems = [close]
        navigationItem.rightBarButtonItems = [refresh]
        updatePromptMenu()
    }

    private func updatePromptMenu() {
        // One compact web toolbar; no duplicated "current material" header.
        let prepare = UIBarButtonItem(image: UIImage(systemName: "text.badge.plus"),
            style: .plain, target: self, action: #selector(importPreparedMaterial))
        prepare.accessibilityLabel = V3L("将本次材料填入 DeepSeek 输入框")
        prepare.accessibilityIdentifier = "impress.deepseek.insert-material"
        prepare.isEnabled = reviewHandoffText?.isEmpty == false

        let send = UIBarButtonItem(image: UIImage(systemName: "arrow.up.circle"),
            style: .plain, target: self, action: #selector(sendWebMessage))
        send.accessibilityLabel = V3L("发送网页输入框中的消息")
        send.accessibilityIdentifier = "impress.deepseek.send"

        let speech = UIBarButtonItem(image: UIImage(systemName: "mic"),
            style: .plain, target: self, action: #selector(startWebSpeech))
        speech.accessibilityLabel = V3L("语音转文字并填入网页输入框")
        speech.accessibilityIdentifier = "impress.deepseek.speech"

        let promptActions = ImpressV3PromptLibrary.load().map { template in
            UIAction(title: template.title,
                     image: UIImage(systemName: "text.quote")) { [weak self] _ in
                self?.writeToWeb(template.content, append: true)
            }
        }
        let promptMenu = UIMenu(title: V3L("插入提示词"), children:
            promptActions.isEmpty ? [
                UIAction(title: V3L("尚无自定义提示词"), attributes: .disabled,
                         handler: { _ in })
            ] : promptActions)
        let nativeHistory = UIAction(title: V3L("本机原生聊天历史"),
            image: UIImage(systemName: "clock.arrow.circlepath")) { [weak self] _ in
            self?.navigationController?.pushViewController(
                ImpressAINativeChatViewController(), animated: true)
        }
        let settings = UIAction(title: V3L("对话设置"),
            image: UIImage(systemName: "gearshape")) { [weak self] _ in
            self?.navigationController?.pushViewController(
                ImpressAISettingsViewController(), animated: true)
        }
        let refresh = UIAction(title: V3L("刷新网页"),
            image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
            self?.webView.reload()
        }
        let copyFallback = UIAction(title: V3L("复制本次材料（备用）"),
            image: UIImage(systemName: "doc.on.doc"),
            attributes: reviewHandoffText?.isEmpty == false ? [] : [.disabled]) {
                [weak self] _ in self?.copyReviewHandoff()
            }
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: [promptMenu, settings, nativeHistory,
                                    copyFallback, refresh]))
        more.accessibilityLabel = V3L("对话设置与历史")
        navigationItem.rightBarButtonItems = [more, speech, send, prepare]
    }

    private func showBridgeError(_ reason: String, fallback: String? = nil) {
        let alert = UIAlertController(title: V3L("网页交互未完成"),
            message: reason, preferredStyle: .alert)
        if let fallback, !fallback.isEmpty {
            alert.addAction(UIAlertAction(title: V3L("复制并手动粘贴"),
                style: .default) { _ in UIPasteboard.general.string = fallback })
        }
        alert.addAction(UIAlertAction(title: V3L("确定"), style: .cancel))
        present(alert, animated: true)
    }

    private func trustedDeepSeekPage() -> Bool {
        guard let url = webView.url else { return false }
        return url.scheme == "https" && url.host == "chat.deepseek.com"
    }

    private func writeToWeb(_ text: String, append: Bool) {
        guard trustedDeepSeekPage() else {
            showBridgeError(V3L("请先打开并登录 DeepSeek 官方网页。"), fallback: text)
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await webView.callAsyncJavaScript(
                    ImpressV3DeepSeekDOMBridge.insert,
                    arguments: ["payload": text, "append": append],
                    in: nil, contentWorld: .page)
                guard let result = value as? [String: Any],
                      result["ok"] as? Bool == true else {
                    showBridgeError(V3L("网页编辑器结构可能已更新，未能确认 React 输入状态。"),
                                    fallback: text)
                    return
                }
                navigationItem.prompt = V3L("已填入网页输入框，尚未发送")
                UIAccessibility.post(notification: .announcement,
                    argument: V3L("文字已经填入网页输入框"))
            } catch {
                showBridgeError(error.localizedDescription, fallback: text)
            }
        }
    }

    @objc private func importPreparedMaterial() {
        guard let value = reviewHandoffText, !value.isEmpty else { return }
        writeToWeb(value, append: true)
    }

    @objc private func startWebSpeech() {
        guard trustedDeepSeekPage() else {
            showBridgeError(V3L("请先打开 DeepSeek 网页。"))
            return
        }
        ImpressSpeechAccessory.presentWeb(from: self) { [weak self] dictated in
            self?.writeToWeb(dictated, append: true)
        }
    }

    @objc private func sendWebMessage() {
        guard trustedDeepSeekPage() else {
            showBridgeError(V3L("当前不是 DeepSeek 官方网页，已阻止发送。"))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await webView.callAsyncJavaScript(
                    ImpressV3DeepSeekDOMBridge.send,
                    arguments: [:], in: nil, contentWorld: .page)
                guard let result = value as? [String: Any],
                      result["ok"] as? Bool == true else {
                    showBridgeError(V3L("找不到可确认的发送按钮；请在网页中手动发送。"))
                    return
                }
                navigationItem.prompt = nil
            } catch {
                showBridgeError(error.localizedDescription)
            }
        }
    }

    @objc private func copyReviewHandoff() {
        guard let value = reviewHandoffText, !value.isEmpty else { return }
        UIPasteboard.general.string = value
        UIAccessibility.post(notification: .announcement,
                             argument: "已复制。请在网页输入框中粘贴并确认发送。")
        copyHandoffButton?.title = "已复制"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.copyHandoffButton?.title = "复制问题"
        }
    }

    private func loadInitialURL() {
        guard let url = URL(string: "https://chat.deepseek.com/") else {
            ImAlertController.warningAlert("无效的URL")
            return
        }

        let request = URLRequest(url: url)
        webView.load(request)
    }

    private func setupFloatingButton() {
        floatingButton.setImage(UIImage(systemName: "plus.circle.fill"), for: .normal)
        floatingButton.tintColor = ImpressV3Appearance.primaryButtonText
        floatingButton.backgroundColor = ImpressV3Appearance.accent
        floatingButton.addTarget(self, action: #selector(createCard), for: .touchUpInside)

        // 添加拖拽手势
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        floatingButton.addGestureRecognizer(panGesture)

        // 添加到视图
        view.addSubview(floatingButton)

        // 设置初始位置（左下角）
        let buttonSize = defaultSpacing * 3
        let spacing = defaultSpacing
        floatingButton.frame = CGRect(
            x: spacing,
            y: view.safeAreaLayoutGuide.layoutFrame.maxY - buttonSize - spacing,
            width: buttonSize,
            height: buttonSize
        )
        floatingButton.setDefaultCorner()
    }

    // MARK: - Actions
    @objc private func refreshPage() {
        webView.reload()
    }

    @objc private func closeWebView() {
        // 取消订阅，避免在控制器不存在时仍尝试present alert
        cancellables.removeAll()
        if let navigation = navigationController,
           navigation.viewControllers.count > 1 {
            navigation.popViewController(animated: true)
        } else {
            dismiss(animated: true, completion: nil)
        }
    }

    @objc private func createCard() {
        let submitVC = ImSubmitViewController(submitModel: ImCardModel())
        submitVC.submitActionResult = { [weak self] (card) in
            // 创建卡片后的处理 - 直接在回调中处理结果，避免单例释放问题
            self?.handleCardInsertResult(card: card)
        }
        
        present(submitVC, animated: true, completion: nil)
    }
    
    /// 处理卡片插入结果 - 避免单例释放导致的alert无法显示问题
    private func handleCardInsertResult(card: ImCardModel) {
        guard let question = card.question, !question.isEmpty else {
            ImAlertController.warningAlert("问题不能为空。")
            return
        }
        
        if card.cardType == CardType.standard.rawValue || card.cardType == CardType.multipleChoice.rawValue {
            guard let answer = card.answer, !answer.isEmpty else {
                ImAlertController.warningAlert("答案不能为空。")
                return
            }
        }
        
        // 直接插入并显示成功提示
        viewModel.insertCard(by: card)
        
        // 延迟显示成功提示，确保插入操作完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard self != nil else {
                // 如果控制器已释放，使用window显示alert
                if let window = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .filter({ $0.activationState == .foregroundActive })
                    .flatMap({ $0.windows })
                    .first(where: { $0.isKeyWindow }) {
                    ImAlertController.alert(message: "卡片已成功创建!", in: window.rootViewController)
                }
                return
            }
            ImAlertController.alert(message: "卡片已成功创建!")
        }
    }

    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)

        switch gesture.state {
        case .began:
            isDragging = false
            initialCenter = floatingButton.center
        case .changed:
            // 移动按钮
            let newCenter = CGPoint(
                x: initialCenter.x + translation.x,
                y: initialCenter.y + translation.y
            )

            // 限制在安全区域内
            let safeAreaInsets = view.safeAreaInsets
            let buttonRadius: CGFloat = defaultSpacing * 1.5
            let minX = safeAreaInsets.left + buttonRadius
            let maxX = view.bounds.width - safeAreaInsets.right - buttonRadius
            let minY = safeAreaInsets.top + buttonRadius
            let maxY = view.bounds.height - safeAreaInsets.bottom - buttonRadius

            let clampedX = min(max(newCenter.x, minX), maxX)
            let clampedY = min(max(newCenter.y, minY), maxY)

            floatingButton.center = CGPoint(x: clampedX, y: clampedY)
            isDragging = true
        case .ended:
            if !isDragging {
                // 如果没有拖拽，则执行点击事件
                createCard()
            } else {
                // 自动吸附到屏幕边缘
                let screenWidth = view.bounds.width
                let centerX = floatingButton.center.x

                UIView.animate(withDuration: 0.3) {
                    let targetX = centerX < screenWidth / 2 ?
                        defaultSpacing + defaultSpacing * 1.5 : // 左边
                        screenWidth - defaultSpacing - defaultSpacing * 1.5 // 右边

                    self.floatingButton.center.x = targetX
                }
            }
        default:
            break
        }
    }

    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // 可以显示加载指示器
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 加载完成
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        ImAlertController.warningAlert("页面加载失败: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 处理导航策略
        decisionHandler(.allow)
    }
}


extension ImWebViewController
{
    func bindAction()
    {
        // 订阅viewModel的actionPublisher，用于接收插入操作的成功或失败通知
        viewModel.actionPublisher
            .receive(on: DispatchQueue.main)
            .sink { result in
                switch result {
                case .success(let message):
                    // 显示成功提示
                    ImAlertController.alert(message: message)
                case .errorOccurred(let error):
                    // 显示失败提示
                    ImAlertController.warningAlert(error.localizedDescription)
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }
}
