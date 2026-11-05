//
//  ImMusicPlayer.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 8/25/25.
//
import AVFoundation
import UIKit

/// 音乐播放工具类，支持随机播放沙盒中mp3文件，前台播放，后台暂停
final class ImMusicPlayer: NSObject, AVAudioPlayerDelegate {
    
    /// 单例实例
    static let shared = ImMusicPlayer()
    
    /// 音频播放器
    private var audioPlayer: AVAudioPlayer?
    
    /// 音乐文件URL数组
    private var musicURLs: [URL] = []
    
    /// 当前播放索引
    private var currentIndex: Int = 0
    
    /// 允许的文件扩展名
    private let allowedExtensions: Set<String> = ["mp3", "wav", "mp4"]
    
    /// 是否正在播放
    private var isPlaying: Bool = false
    
    /// 监听前后台切换的观察者
    private var observers: [NSObjectProtocol] = []

    /// 标记是否已提示佩戴耳机
    private var hasShownHeadphoneAlert: Bool = false
    
    
    

    // MARK: - Init
    private override init() {
        super.init()
        loadMusicFiles()      // 初始化时加载音乐文件
        setupNotifications()  // 设置前后台通知监听
    }
    
    deinit {
        removeNotifications()
        stopPlaying()
    }
    
    /// 开始随机播放
    func startPlaying() {
        guard !musicURLs.isEmpty else {
            zcLog("没有找到音乐文件")
            return
        }
        
        // 提示用户佩戴耳机，并检查连接状态
        if !checkHeadphoneConnection() {
            if !hasShownHeadphoneAlert {
                ImAlertController.alert(message: "建议佩戴耳机更享受哦~")
                hasShownHeadphoneAlert = true
            }
            return
        }
        
        playRandom()
    }
    
    /// 检查耳机或蓝牙设备是否连接
    private func checkHeadphoneConnection() -> Bool {
        let session = AVAudioSession.sharedInstance()
        let currentRoute = session.currentRoute
        let outputs = currentRoute.outputs

        return outputs.contains { output in
            switch output.portType {
            case .headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
                return true
            default:
                return false
            }
        }
    }
    
    /// 停止播放
    func stopPlaying() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
    }
    
    /// 加载沙盒中所有允许格式的音乐文件
    private func loadMusicFiles() {
        musicURLs.removeAll()
        
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: musicPath, isDirectory: &isDirectory), isDirectory.boolValue {
            do {
                let musicFolderURL = URL(fileURLWithPath: musicPath, isDirectory: true)
                let files = try fileManager.contentsOfDirectory(at: musicFolderURL, includingPropertiesForKeys: nil, options: [])
                // 过滤允许的文件格式
                musicURLs = files.filter { url in
                    allowedExtensions.contains(url.pathExtension.lowercased())
                }
            } catch {
                zcLog("读取ImMusic文件夹失败: \(error)")
            }
        } else {
            zcLog("ImMusic文件夹不存在或不是目录")
        }
    }
    
    /// 播放随机一首音乐
    private func playRandom() {
        guard !musicURLs.isEmpty else { return }
        
        currentIndex = Int.random(in: 0..<musicURLs.count)
        let url = musicURLs[currentIndex]
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            isPlaying = true
            zcLog("开始播放: \(url.lastPathComponent)")
        } catch {
            zcLog("播放失败: \(error)")
        }
    }
    
    /// 播放下一首（随机）
    private func playNext() {
        playRandom()
    }
    
    /// 监听前后台切换，前台播放，后台暂停
    private func setupNotifications() {
        let center = NotificationCenter.default
        
        let willResignActive = center.addObserver(forName: UIApplication.willResignActiveNotification,
                                                  object: nil,
                                                  queue: .main) { [weak self] _ in
            self?.pausePlaying()
        }
        
        let didBecomeActive = center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                 object: nil,
                                                 queue: .main) { [weak self] _ in
            self?.resumePlaying()
        }
        
        observers.append(contentsOf: [willResignActive, didBecomeActive])
    }
    
    private func removeNotifications() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
    }
    
    private func pausePlaying() {
        guard isPlaying else { return }
        audioPlayer?.pause()
        zcLog("暂停播放（进入后台）")
    }
    
    private func resumePlaying() {
        guard isPlaying else { return }
        audioPlayer?.play()
        zcLog("恢复播放（进入前台）")
    }
    
    // MARK: - AVAudioPlayerDelegate
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // 播放完毕，自动播放下一首
        playNext()
    }
}

