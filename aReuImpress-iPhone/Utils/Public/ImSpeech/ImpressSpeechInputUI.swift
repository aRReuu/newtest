import UIKit
import Vision
import VisionKit

// MARK: - Text-only, version-aware insertion

enum ImpressSpeechInsertFailure: LocalizedError {
    case missingInput, changedWhileRecording, invalidSelection, rejected
    var errorDescription: String? {
        switch self {
        case .missingInput: return V3L("原输入框已关闭，本次识别不会修改任何内容。")
        case .changedWhileRecording: return V3L("录音期间文本已发生变化；为避免覆盖，请重新开始。")
        case .invalidSelection: return V3L("原光标位置已失效；本次识别没有插入。")
        case .rejected: return V3L("当前编辑器拒绝这次文本插入。")
        }
    }
}

enum ImpressSpeechTextInsertion {
    /// NSString UTF-16 offsets are the offsets used by UIKit text ranges.
    static func inserting(_ dictated: String, into original: String,
                          selected: NSRange) -> String? {
        let length = (original as NSString).length
        guard selected.location != NSNotFound, selected.location >= 0,
              selected.length >= 0, selected.location <= length,
              selected.length <= length - selected.location else { return nil }
        return (original as NSString).replacingCharacters(in: selected, with: dictated)
    }
}

@MainActor
final class ImpressSpeechTextBinding {
    private weak var view: UIView?
    private let original: String
    private let selection: NSRange

    init?(view: UIView) {
        if let editor = view as? UITextView, editor.isEditable {
            self.original = editor.text ?? ""
            self.selection = editor.selectedRange
        } else if let field = view as? UITextField, field.isEnabled {
            self.original = field.text ?? ""
            if let range = field.selectedTextRange {
                let from = field.offset(from: field.beginningOfDocument, to: range.start)
                let to = field.offset(from: field.beginningOfDocument, to: range.end)
                self.selection = NSRange(location: from, length: to - from)
            } else {
                self.selection = NSRange(location: (self.original as NSString).length,
                                          length: 0)
            }
        } else {
            return nil
        }
        self.view = view
    }

    func commit(_ dictated: String) throws {
        guard let view else { throw ImpressSpeechInsertFailure.missingInput }
        let source: String
        if let editor = view as? UITextView { source = editor.text ?? "" }
        else if let field = view as? UITextField { source = field.text ?? "" }
        else { throw ImpressSpeechInsertFailure.missingInput }
        guard source == original else { throw ImpressSpeechInsertFailure.changedWhileRecording }
        guard let text = ImpressSpeechTextInsertion.inserting(dictated, into: original,
                                                                selected: selection) else {
            throw ImpressSpeechInsertFailure.invalidSelection
        }
        let cursor = selection.location + (dictated as NSString).length
        if let editor = view as? UITextView {
            // An explicit undo group allows the entire dictation to be
            // reverted as a single operation without changing the user's data.
            editor.undoManager?.registerUndo(withTarget: editor) { target in
                target.text = source
                target.delegate?.textViewDidChange?(target)
            }
            editor.text = text
            editor.selectedRange = NSRange(location: cursor, length: 0)
            editor.delegate?.textViewDidChange?(editor)
        } else if let field = view as? UITextField {
            field.undoManager?.registerUndo(withTarget: field) { target in
                target.text = source
                target.sendActions(for: .editingChanged)
            }
            field.text = text
            field.sendActions(for: .editingChanged)
        }
    }
}

// MARK: - One native microphone control shared by all app editors

@MainActor
enum ImpressSpeechAccessory {
    static func install(on textView: UITextView) {
        guard textView.isEditable else { return }
        textView.inputAccessoryView = toolbar(for: textView)
    }

    static func install(on field: UITextField) {
        field.inputAccessoryView = toolbar(for: field)
    }

    // Card composer uses the same OCR/STT bar; video capture is a contextual tool.
    static func install(on textView: UITextView, captureVideo: @escaping () -> Void) {
        guard textView.isEditable else { return }
        textView.inputAccessoryView = toolbar(for: textView, captureVideo: captureVideo)
    }

    private static func toolbar(for field: UIView,
                                captureVideo: (() -> Void)? = nil) -> UIToolbar {
        let bar = UIToolbar()
        let action = UIAction { [weak field] _ in
            guard let field else { return }
            present(for: field)
        }
        let microphone = UIBarButtonItem(
            title: nil, image: UIImage(systemName: "mic"),
            primaryAction: action, menu: nil)
        microphone.accessibilityLabel = V3L("开始语音输入")
        microphone.accessibilityIdentifier = "impress.speech.microphone"
        let camera = UIBarButtonItem(title: nil,
            image: UIImage(systemName: "text.viewfinder"),
            primaryAction: UIAction { [weak field] _ in
                guard let field else { return }
                presentOCR(for: field)
            }, menu: nil)
        camera.accessibilityLabel = V3L("拍照识别文字")
        camera.accessibilityIdentifier = "impress.ocr.keyboard"
        var actions = [UIBarButtonItem(barButtonSystemItem: .flexibleSpace,
                                       target: nil, action: nil)]
        if let captureVideo {
            let video = UIBarButtonItem(title: nil,
                image: UIImage(systemName: "video.badge.plus"),
                primaryAction: UIAction { _ in captureVideo() }, menu: nil)
            video.accessibilityLabel = V3L("拍摄视频")
            video.accessibilityIdentifier = "impress.card.video.keyboard"
            actions.append(video)
        }
        actions.append(contentsOf: [camera, microphone])
        bar.items = actions
        bar.sizeToFit()
        return bar
    }

    // The same safe dictation panel can be invoked by an in-composer button,
    // not only the keyboard accessory toolbar.
    static func present(for field: UIView) {
        guard let binding = ImpressSpeechTextBinding(view: field) else { return }
        var current: UIResponder? = field
        var owner: UIViewController?
        while let responder = current {
            if let controller = responder as? UIViewController {
                owner = controller
                break
            }
            current = responder.next
        }
        guard let owner else { return }
        let editor = ImpressSpeechPanelViewController(binding: binding)
        editor.modalPresentationStyle = .pageSheet
        if let sheet = editor.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        owner.present(editor, animated: true)
    }
    /// For a browser-hosted React input, the recognized string is delivered
    /// directly to the web bridge. No temporary native chat draft is created.
    static func presentWeb(from owner: UIViewController,
                           onRecognized: @escaping (String) -> Void) {
        let recorder = ImpressSpeechPanelViewController(onRecognized: onRecognized)
        recorder.modalPresentationStyle = .pageSheet
        if let sheet = recorder.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        owner.present(recorder, animated: true)
    }

    static func presentWebOCR(from owner: UIViewController,
                              onRecognized: @escaping (String) -> Void) {
        let camera = ImpressOCRCaptureViewController(onRecognized: onRecognized)
        camera.modalPresentationStyle = .fullScreen
        owner.present(camera, animated: true)
    }

    static func presentOCR(for field: UIView) {
        guard let binding = ImpressSpeechTextBinding(view: field) else { return }
        var responder: UIResponder? = field
        while let current = responder {
            if let owner = current as? UIViewController {
                let camera = ImpressOCRCaptureViewController(binding: binding)
                camera.modalPresentationStyle = .fullScreen
                owner.present(camera, animated: true)
                return
            }
            responder = current.next
        }
    }

}

// MARK: - Native presentation; provisional speech is never persisted

@MainActor
final class ImpressSpeechPanelViewController: UIViewController {
    private let binding: ImpressSpeechTextBinding?
    private let onRecognized: ((String) -> Void)?
    private let service = ImpressSpeechService.shared
    private let titleLabel = UILabel()
    private let transcript = UITextView()
    private let action = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private var request: Task<Void, Never>?
    private var recording = false
    private var committing = false
    private var started = false

    init(binding: ImpressSpeechTextBinding) {
        self.binding = binding
        self.onRecognized = nil
        super.init(nibName: nil, bundle: nil)
    }

    init(onRecognized: @escaping (String) -> Void) {
        self.binding = nil
        self.onRecognized = onRecognized
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("programmatic init required") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ImpressV3Appearance.page
        isModalInPresentation = true
        titleLabel.font = ImpressV3Appearance.Typography.heading
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = ImpressV3Appearance.primaryText
        titleLabel.text = V3L("准备语音输入")
        titleLabel.numberOfLines = 2
        titleLabel.accessibilityIdentifier = "impress.speech.status"

        transcript.backgroundColor = ImpressV3Appearance.surface
        transcript.layer.cornerRadius = ImpressV3Appearance.Radius.card
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.font = ImpressV3Appearance.Typography.body
        transcript.adjustsFontForContentSizeCategory = true
        transcript.textColor = ImpressV3Appearance.primaryText
        transcript.text = V3L("识别文本将在此预览，结束后才插入原编辑框。")
        transcript.accessibilityIdentifier = "impress.speech.preview"

        ImpressV3Appearance.styleQuietButton(cancelButton, title: V3L("取消"))
        cancelButton.accessibilityIdentifier = "impress.speech.cancel"
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        ImpressV3NativeButtonAppearance.primary(action, title: V3L("开始录音"))
        action.accessibilityIdentifier = "impress.speech.action"
        action.addTarget(self, action: #selector(tappedAction), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [cancelButton, action])
        buttons.axis = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = ImpressV3Appearance.Metrics.rowSpacing

        let content = UIStackView(arrangedSubviews: [titleLabel, transcript, buttons])
        content.axis = .vertical
        content.spacing = ImpressV3Appearance.Metrics.sectionSpacing
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: ImpressV3Appearance.Metrics.screenInset),
            content.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: ImpressV3Appearance.Metrics.screenInset),
            content.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -ImpressV3Appearance.Metrics.screenInset),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -ImpressV3Appearance.Metrics.screenInset),
            transcript.heightAnchor.constraint(greaterThanOrEqualToConstant: ImpressV3Appearance.Metrics.speechPreviewMinHeight)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // One tap on the keyboard's microphone opens the native recorder.
        if !started {
            started = true
            tappedAction()
        }
    }

    @objc private func tappedAction() {
        guard request == nil else { return }
        if recording {
            finishRecording()
        } else {
            request = Task { [weak self] in
                guard let self else { return }
                await self.beginRecording()
            }
        }
    }

    private func beginRecording() async {
        defer { request = nil }
        guard !recording else { return }
        let choice = ImpressSpeechLocale.selected()
        let availability = await service.availability(for: choice)
        guard !Task.isCancelled else { return }
        guard availability.engine != nil else {
            showError(ImpressSpeechFailure.unsupported)
            return
        }
        if !availability.installed {
            titleLabel.text = V3L("识别模型未安装")
            let shouldInstall = await requestDownloadConsent()
            guard shouldInstall else { return }
            titleLabel.text = V3L("正在安装 Apple 端侧模型…")
            action.isEnabled = false
            do { try await service.downloadModel(for: choice) }
            catch {
                action.isEnabled = true
                showError(error)
                return
            }
        }
        guard !Task.isCancelled else { return }
        titleLabel.text = V3L("正在启动录音…")
        action.isEnabled = false
        do {
            try await service.start(choice: choice) { [weak self] finalized, preview in
                guard let self else { return }
                self.transcript.text = preview
                self.transcript.accessibilityValue = finalized
            }
            recording = true
            titleLabel.text = V3L("正在聆听")
            ImpressV3NativeButtonAppearance.primary(action, title: V3L("结束并插入"))
        } catch {
            titleLabel.text = V3L("无法开始录音")
            showError(error)
        }
        action.isEnabled = true
    }

    private func requestDownloadConsent() async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: V3L("下载 Apple 识别模型？"),
                message: V3L("仅首次需要联网下载；录音和转文字在设备端处理。"),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel) {
                _ in continuation.resume(returning: false)
            })
            alert.addAction(UIAlertAction(title: V3L("下载并继续"), style: .default) {
                _ in continuation.resume(returning: true)
            })
            present(alert, animated: true)
        }
    }

    private func finishRecording() {
        guard !committing else { return }
        committing = true
        action.isEnabled = false
        cancelButton.isEnabled = false
        titleLabel.text = V3L("正在完成识别…")
        request = Task { [weak self] in
            guard let self else { return }
            defer {
                self.request = nil
                self.committing = false
                self.cancelButton.isEnabled = true
                self.action.isEnabled = true
            }
            do {
                let final = try await self.service.finish()
                if let binding = self.binding {
                    try binding.commit(final)
                } else {
                    self.onRecognized?(final)
                }
                self.recording = false
                self.dismiss(animated: true)
            } catch {
                self.recording = false
                ImpressV3NativeButtonAppearance.primary(self.action, title: V3L("重新录音"))
                self.showError(error)
            }
        }
    }

    @objc private func cancel() {
        request?.cancel()
        request = Task { [weak self] in
            guard let self else { return }
            await self.service.cancel()
            self.recording = false
            self.dismiss(animated: true)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed && !committing {
            Task { await service.cancel() }
        }
    }

    private func showError(_ error: Error) {
        titleLabel.text = V3L("语音输入未完成")
        let alert = UIAlertController(title: V3L("无法完成语音输入"),
                                      message: error.localizedDescription,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        present(alert, animated: true)
    }
}


// MARK: - On-device document-camera OCR; never writes the Vault or chat history
@MainActor
final class ImpressOCRCaptureViewController: UIViewController,
                                            VNDocumentCameraViewControllerDelegate {
    private let binding: ImpressSpeechTextBinding?
    private let onRecognized: ((String) -> Void)?
    private var started = false
    private let status = UIActivityIndicatorView(style: .large)

    init(binding: ImpressSpeechTextBinding) {
        self.binding = binding
        self.onRecognized = nil
        super.init(nibName: nil, bundle: nil)
    }

    init(onRecognized: @escaping (String) -> Void) {
        self.binding = nil
        self.onRecognized = onRecognized
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("programmatic init required") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ImpressV3Appearance.page
        status.translatesAutoresizingMaskIntoConstraints = false
        status.hidesWhenStopped = true
        view.addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        launchScanner()
    }

    private func launchScanner() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            showProblem(V3L("当前设备不支持相机扫描。"))
            return
        }
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = self
        scanner.modalPresentationStyle = .fullScreen
        present(scanner, animated: true)
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        controller.dismiss(animated: false) { [weak self] in
            self?.dismiss(animated: true)
        }
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                      didFailWithError error: Error) {
        controller.dismiss(animated: false) { [weak self] in
            self?.showProblem(error.localizedDescription)
        }
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                      didFinishWith scan: VNDocumentCameraScan) {
        // Image bytes never leave the device, and are never backed up.
        let pages = (0..<scan.pageCount).compactMap { scan.imageOfPage(at: $0).cgImage }
        controller.dismiss(animated: false) { [weak self] in
            guard let self else { return }
            status.startAnimating()
            DispatchQueue.global(qos: .userInitiated).async {
                let result: Result<String, Error> = Result {
                    let text = try pages.map { page -> String in
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .accurate
                        request.usesLanguageCorrection = true
                        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                        try VNImageRequestHandler(cgImage: page, options: [:])
                            .perform([request])
                        return (request.results ?? [])
                            .compactMap { $0.topCandidates(1).first?.string }
                            .joined(separator: "\n")
                    }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                    return text
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.status.stopAnimating()
                    switch result {
                    case .success(let recognized):
                        guard !recognized.trimmingCharacters(
                            in: .whitespacesAndNewlines).isEmpty else {
                            self.showProblem(V3L("未能识别到文字，请重新拍照。"))
                            return
                        }
                        do {
                            if let binding = self.binding {
                                try binding.commit(recognized)
                            } else {
                                self.onRecognized?(recognized)
                            }
                            self.dismiss(animated: true)
                        } catch {
                            self.showProblem(error.localizedDescription)
                        }
                    case .failure(let error):
                        self.showProblem(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func showProblem(_ message: String) {
        let alert = UIAlertController(title: V3L("拍照识别未完成"),
            message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("重试"), style: .default) {
            [weak self] _ in self?.launchScanner()
        })
        alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel) {
            [weak self] _ in self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }
}


// MARK: - App-wide attachment without UIKit method swizzling
// Observe the system's native editing notifications. Existing bespoke
// inputAccessoryView implementations are left intact, never overwritten.
@MainActor
final class ImpressGlobalTextInputTools: NSObject {
    static let shared = ImpressGlobalTextInputTools()
    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(self,
            selector: #selector(editingDidBegin(_:)),
            name: UITextField.textDidBeginEditingNotification, object: nil)
        NotificationCenter.default.addObserver(self,
            selector: #selector(editingDidBegin(_:)),
            name: UITextView.textDidBeginEditingNotification, object: nil)
    }

    @objc private func editingDidBegin(_ notification: Notification) {
        if let field = notification.object as? UITextField,
           field.isEnabled, field.inputAccessoryView == nil {
            ImpressSpeechAccessory.install(on: field)
            field.reloadInputViews()
        } else if let editor = notification.object as? UITextView,
                  editor.isEditable, editor.inputAccessoryView == nil {
            ImpressSpeechAccessory.install(on: editor)
            editor.reloadInputViews()
        }
    }
}
