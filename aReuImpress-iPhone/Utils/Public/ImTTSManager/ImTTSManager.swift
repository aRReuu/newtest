//
//  ImTTSManager.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 12/15/24.
//

import UIKit
import AVFoundation

/// 语音合成管理器 - 负责文本转语音功能
/// 支持中英文自动语言检测，权限管理，边界条件处理
class ImTTSManager: NSObject {
    static let shared = ImTTSManager()

    private let speechSynthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?

    /// 播放完成回调
    var onPlaybackFinished: (() -> Void)?
    /// 播放错误回调
    var onPlaybackError: ((Error) -> Void)?

    private override init() {
        super.init()
        speechSynthesizer.delegate = self
        setupAudioSession()
    }

    /// 检查并请求语音播放权限（兼容Swift 5.0）
    /// - Parameter completion: 权限检查完成回调
    func requestPermissions(completion: @escaping (Bool) -> Void) {
        // TTS 主要依赖于音频播放权限，系统中通常默认授予
        // 如果需要检查麦克风权限，可以取消下面的注释
        /*
        let permission = AVAudioSession.sharedInstance().recordPermission
        switch permission {
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                completion(granted)
            }
        case .denied:
            completion(false)
        case .granted:
            completion(true)
        @unknown default:
            completion(false)
        }
        */
        completion(true)
    }

    /// 播放文本语音
    /// - Parameter text: 要播放的文本内容
    func speak(text: String) {
        // 边界条件：空文本过滤
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            zcLog("TTS: 文本为空，跳过播放")
            return
        }

        // 并发控制：停止当前播放
        stop()

        // 权限检查（兼容Swift 5.0）
        requestPermissions { [weak self] hasPermission in
            guard let self = self, hasPermission else {
                zcLog("TTS: 权限被拒绝")
                DispatchQueue.main.async {
                    ImAlertController.warningAlert("语音播放权限被拒绝，请在设置中启用")
                }
                return
            }

            // 语言检测
            let language = self.detectLanguage(for: trimmedText)
            zcLog("TTS: 检测到语言 - \(language)")

            // 创建播放对象
            let utterance = AVSpeechUtterance(string: trimmedText)
            if let voice = AVSpeechSynthesisVoice(language: language) {
                utterance.voice = voice
            }
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.pitchMultiplier = 1.0
            utterance.volume = 1.0

            // 存储当前播放对象用于取消
            self.currentUtterance = utterance

            // 开始播放
            self.speechSynthesizer.speak(utterance)
        }
    }

    /// 停止当前播放
    func stop() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        currentUtterance = nil
    }

    /// 获取当前是否正在播放
    /// - Returns: 是否正在播放
    func isSpeaking() -> Bool {
        return speechSynthesizer.isSpeaking
    }

    /// 语言检测 - 根据文本内容判断使用中英文发音
    /// - Parameter text: 检查的文本
    /// - Returns: 语言代码 ("zh-CN" 或 "en-US")
    private func detectLanguage(for text: String) -> String {
        // 检查是否包含中文字符（Unicode范围：4E00-9FFF）
        let chineseCharacterSet = CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}")
        if text.rangeOfCharacter(from: chineseCharacterSet) != nil {
            return "zh-CN"
        }

        // 检查是否包含日语字符（可选）
        // let japaneseCharacterSet = CharacterSet(charactersIn: "\u{3040}"..."\u{309F}")

        // 默认英文
        return "en-US"
    }

    /// 设置音频会话，确保TTS正常播放
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback,
                                                          mode: .default,
                                                          options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch let error as NSError {
            zcLog("TTS: 音频会话设置失败 - \(error.localizedDescription)")
            // 错误信息可以通过回调传递，但不中断初始化
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate
extension ImTTSManager: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        zcLog("TTS: 播放完成")
        currentUtterance = nil
        DispatchQueue.main.async {
            self.onPlaybackFinished?()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        zcLog("TTS: 播放被取消")
        currentUtterance = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        zcLog("TTS: 开始播放")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        // 可选：播放进度回调
        // zcLog("TTS: 正在播放范围 \(characterRange)")
    }
}
