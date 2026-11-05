//
//  ImWebViewController.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 1/15/26.
//

import UIKit
import WebKit
import Combine

/// Pure preparation: no network request, JavaScript injection or automatic send.
/// The user's customized local prompt takes precedence over the fallback.
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
        if let handoff = reviewHandoffText {
            if !handoff.isEmpty {
                let copy = UIBarButtonItem(title: "复制问题", style: .plain,
                                           target: self, action: #selector(copyReviewHandoff))
                copy.accessibilityLabel = "复制本题到剪贴板"
                copyHandoffButton = copy
                navigationItem.rightBarButtonItems = [copy]
            } else {
                navigationItem.rightBarButtonItems = [refresh]
            }
        } else {
            navigationItem.leftBarButtonItems = [close, refresh]
        }
        updatePromptMenu()
    }

    private func updatePromptMenu() {
        let templates = ImpressV3PromptLibrary.load()
        let actions = templates.map { template in
            UIAction(title: template.title, image: UIImage(systemName: "doc.on.doc")) { _ in
                // One direct user action: copy only this explicit local template.
                // No script injection, hidden clipboard read or network send.
                UIPasteboard.general.string = template.content
                UIAccessibility.post(notification: .announcement,
                                     argument: "提示词已复制。请自行粘贴并确认发送。")
            }
        }
        let menu = UIMenu(title: "复制提示词", children: actions)
        let item = UIBarButtonItem(image: UIImage(systemName: "text.quote"),
                                   menu: menu)
        item.accessibilityLabel = "从提示词库复制"
        var others = navigationItem.rightBarButtonItems ?? []
        others.removeAll { $0.accessibilityLabel == "从提示词库复制" }
        others.append(item)
        navigationItem.rightBarButtonItems = others
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
