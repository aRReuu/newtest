//
//  ImGridViewController.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 1/16/26.
//
import UIKit
import MarkdownView // 确保引入了库
import WCDBSwift

class ImGridViewController: ImBaseViewController {

    // UI控件
    private var idTextField: UITextField!
    private var loadButton: UIButton!
    private var mdView: MarkdownView!

    // 数据持久化键
    private let noteIDKey = "ImGridViewController_NoteID"

    // 当前笔记ID，从持久化存储中读取
    private var currentNoteID: Int {
        get {
            let savedID = UserDefaults.standard.integer(forKey: noteIDKey)
            return savedID > 0 ? savedID : 117
        }
        set {
            // 保存到UserDefaults
            UserDefaults.standard.set(newValue, forKey: noteIDKey)
            UserDefaults.standard.synchronize()
        }
    }

    convenience init(noteID: Int) {
        self.init()
        // 如果通过初始化器传入ID，则覆盖持久化值
        if noteID > 0 {
            self.currentNoteID = noteID
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupUI()
        setupConstraints()
        loadInitialNote()
    }

    /// 设置UI控件
    private func setupUI() {
        // 设置标题
        title = "笔记查看器"

        // 创建ID输入框，用于导航栏titleView
        idTextField = UITextField()
        idTextField.placeholder = "输入笔记ID"
        idTextField.text = "\(currentNoteID)"
        idTextField.borderStyle = .roundedRect
        idTextField.keyboardType = .numberPad
        idTextField.returnKeyType = .done
        idTextField.delegate = self
        idTextField.frame = CGRect(x: 0, y: 0, width: 120, height: 30)
        navigationItem.titleView = idTextField

        // 创建加载按钮，用于导航栏右侧
        loadButton = UIButton(type: .system)
        loadButton.setTitle("加载笔记", for: .normal)
        loadButton.tintColor = ImpressV3Appearance.navigationActionInk
        loadButton.addTarget(self, action: #selector(loadButtonTapped), for: .touchUpInside)
        loadButton.frame = CGRect(x: 0, y: 0, width: 80, height: 30)
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: loadButton)

        // 初始化 MarkdownView
        mdView = MarkdownView()
        mdView.isOpaque = false
        mdView.backgroundColor = .clear
        view.addSubview(mdView)

        // 添加键盘隐藏手势
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        view.addGestureRecognizer(tapGesture)
    }

    /// 设置约束
    private func setupConstraints() {
        mdView.translatesAutoresizingMaskIntoConstraints = false

        let safeArea = view.safeAreaLayoutGuide

        NSLayoutConstraint.activate([
            // MarkdownView约束
            mdView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            mdView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            mdView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            mdView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor)
        ])
    }

    /// 加载初始笔记
    private func loadInitialNote() {
        loadNoteContent()
    }

    /// 从数据库加载笔记内容
    private func loadNoteContent() {
        // 定义适配暗夜模式的 CSS
        let adaptiveCSS = """
        /* 全局字体优化 */
        body {
            font-family: -apple-system, system-ui, sans-serif;
            font-size: 16px;
            line-height: 1.6;
            padding: 20px;
        }

        /* --- 默认 (白天模式) --- */
        body { color: #24292e; background-color: #ffffff; }
        table tr { background-color: #ffffff; border-top: 1px solid #c6cbd1; }
        table tr:nth-child(2n) { background-color: #f6f8fa; }
        table th, table td { border: 1px solid #dfe2e5; padding: 6px 13px; }

        /* --- 暗夜模式 (Dark Mode) --- */
        @media (prefers-color-scheme: dark) {
            body { color: #c9d1d9; background-color: #0d1117; }

            /* 链接颜色变浅一点 */
            a { color: #58a6ff; }

            /* 表格边框和背景变深 */
            table tr { background-color: #0d1117; border-top: 1px solid #30363d; }
            table tr:nth-child(2n) { background-color: #161b22; } /* 偶数行颜色 */
            table th, table td { border: 1px solid #30363d; }
            table th { background-color: #161b22; }

            /* 标题底下的线 */
            h1, h2 { border-bottom-color: #21262d; }

            /* 代码块背景 */
            code, pre { background-color: #161b22; }
        }
        """

        // 显示加载状态
        loadButton.isEnabled = false
        loadButton.setTitle("加载中...", for: .normal)

        dbShare.queryOneObjectFromDB(table: ImDBTableType.notes.description,
                                   cls: ImNoteModel.self,
                                   where: ImNoteModel.Properties.identifier == currentNoteID) { [weak self] result in
            guard let self = self else { return }

            let markdownString: String
            switch result {
            case .success(let note):
                // 边界条件：检查笔记内容是否存在
                if let content = note.markdownText, !content.isEmpty {
                    markdownString = content
                    print("成功加载笔记 ID \(self.currentNoteID) 的内容")
                } else {
                    // 笔记存在但内容为空
                    markdownString = """
                    # 笔记内容为空

                    笔记 ID: \(self.currentNoteID)

                    该笔记存在但没有内容。
                    """
                    print("笔记 ID \(self.currentNoteID) 存在但内容为空")
                }
            case .failure(let error):
                // 边界条件：笔记不存在或其他数据库错误
                markdownString = """
                # 无法加载笔记

                笔记 ID: \(self.currentNoteID)

                错误: \(error.localizedDescription)

                可能的原因：
                - 笔记不存在
                - 数据库连接失败
                - 输入的ID无效
                """
                print("加载笔记 ID \(self.currentNoteID) 失败: \(error.localizedDescription)")
            }

            // 加载内容并注入 CSS
            self.mdView.load(markdown: markdownString, css: adaptiveCSS)

            // 渲染完成回调
            self.mdView.onRendered = { height in
                print("渲染完成，高度: \(height)")
            }

            // 恢复按钮状态
            DispatchQueue.main.async {
                self.loadButton.isEnabled = true
                self.loadButton.setTitle("加载笔记", for: .normal)
            }
        }
    }

    /// 加载按钮点击事件
    @objc private func loadButtonTapped() {
        // 输入验证
        guard let text = idTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            showAlert(message: "请输入笔记ID")
            return
        }

        guard let newID = Int(text), newID > 0 else {
            showAlert(message: "请输入有效的正整数ID")
            return
        }

        // 边界条件：防止重复加载相同的ID
        if newID == currentNoteID {
            showAlert(message: "已经是当前笔记ID")
            return
        }

        // 更新当前ID并持久化
        currentNoteID = newID

        // 重新加载笔记
        loadNoteContent()

        // 隐藏键盘
        dismissKeyboard()
    }

    /// 隐藏键盘
    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    /// 显示提示信息
    private func showAlert(message: String) {
        let alert = UIAlertController(title: "提示", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - UITextFieldDelegate
extension ImGridViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        // 点击Return键时触发加载
        loadButtonTapped()
        return true
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        // 只允许数字输入
        let allowedCharacters = CharacterSet.decimalDigits
        let characterSet = CharacterSet(charactersIn: string)
        return allowedCharacters.isSuperset(of: characterSet) || string.isEmpty
    }
}
