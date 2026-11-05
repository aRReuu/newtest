
import UIKit

/// 记忆卡片覆盖层视图
/// 负责在卡片滑动时显示方向指示器，提供视觉反馈
/// 支持四个滑动方向：左、右、上、下，每个方向有独特的图标和颜色
class ImMemoryCardOverlay: UIView
{
    /// 布局和动画相关的常量
    private enum Constants {
        static let paddingTop: CGFloat = 30.0
        static let paddingRight: CGFloat = 14.0
        static let paddingBottom: CGFloat = 20.0
        static let rotationAngleLeftRight: CGFloat = CGFloat.pi / 10
        static let rotationAngleUp: CGFloat = -CGFloat.pi / 20
        static let overlaySize: CGFloat = 80.0
    }

    init(direction: SwipeDirection)
    {
        super.init(frame: .zero)
        setupOverlay(for: direction)
    }

    required init?(coder: NSCoder)
    {
        return nil
    }

    private func setupOverlay(for direction: SwipeDirection)
    {
        let rotationAngle: CGFloat
        switch direction {
        case .left:
            rotationAngle = Constants.rotationAngleLeftRight
        case .right:
            rotationAngle = -Constants.rotationAngleLeftRight
        case .up:
            rotationAngle = Constants.rotationAngleUp
        case .down:
            rotationAngle = Constants.rotationAngleLeftRight
        }

        let level = direction.toLevel
        let overlayView = ImMemoryCardOverlayView(
            direction: direction,
            color: direction.toLevelColor,
            rotation: rotationAngle
        )
        addSubview(overlayView)
        overlayView.translatesAutoresizingMaskIntoConstraints = false

        // 根据方向调整位置 - 交换左/右和上/下的位置
        switch direction {
        case .left:
            overlayView.leadingAnchor.constraint(equalTo: centerXAnchor, constant: defaultSpacing * 2).isActive = true
            overlayView.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        case .right:
            overlayView.trailingAnchor.constraint(equalTo: centerXAnchor, constant: -defaultSpacing * 2).isActive = true
            overlayView.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        case .up:
            overlayView.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
            overlayView.topAnchor.constraint(equalTo: centerYAnchor, constant: defaultSpacing * 2).isActive = true
        case .down:
            overlayView.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
            overlayView.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -defaultSpacing * 2).isActive = true
        }

        // 移除固定高度约束，使用内容自适应宽度
        overlayView.widthAnchor.constraint(equalToConstant: Constants.overlaySize).isActive = true
        // 高度由内容决定，不设置固定高度约束
    }
}




private class ImMemoryCardOverlayView: UIView
{
    private let iconView: UIImageView
    private let label: UILabel
    private let adaptiveStrokeColor: UIColor
    private var imageCache: [String: UIImage] = [:] // 简单的内存缓存

    init(direction: SwipeDirection, color: UIColor, rotation: CGFloat)
    {
        let iconView = UIImageView()
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = color

        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        label.textColor = color
        label.textAlignment = .center

        self.iconView = iconView
        self.label = label
        self.adaptiveStrokeColor = color

        super.init(frame: .zero)

        // 使用语义化颜色设置背景，提升视觉效果
        backgroundColor = color.withAlphaComponent(highlightAlpha)
        layer.borderColor = color.resolvedColor(with: traitCollection).cgColor
        layer.borderWidth = 2
        layer.cornerRadius = 12
        layer.shadowColor = color.resolvedColor(with: traitCollection).cgColor
        layer.shadowOpacity = 0.3
        layer.shadowOffset = CGSize(width: 0, height: 4)
        layer.shadowRadius = 8

        // 添加毛玻璃效果，提升视觉层次
        let blurEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        let blurView = UIVisualEffectView(effect: blurEffect)
        blurView.frame = bounds
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blurView.layer.cornerRadius = 12
        blurView.layer.masksToBounds = true
        insertSubview(blurView, at: 0)

        transform = CGAffineTransform(rotationAngle: rotation)

        addSubview(iconView)
        addSubview(label)

        // 设置图标和文字 - 使用资源图片替代SF Symbols，带容错处理
        setupIconAndLabel(for: direction)
        label.text = direction.toLevel.title
        setupConstraints()
        //
//        zcLog("ImMemoryCardOverlayView 初始化完成 - 方向: \(direction), 图片: \(getImageName(for: direction))")
    }

    /// 设置图标和标签，带容错处理和内存优化
    private func setupIconAndLabel(for direction: SwipeDirection) {
        let imageName = getImageName(for: direction)

        // 尝试从缓存获取图片
        if let cachedImage = imageCache[imageName] {
            iconView.image = cachedImage.withRenderingMode(.alwaysTemplate)
            iconView.tintColor = direction.toLevelColor
            return
        }

        // 加载图片并处理边界条件
        if let image = loadImageSafely(named: imageName) {
            // 图片适配：根据屏幕尺寸调整图片大小
            let adaptedImage = adaptImageForScreen(image: image)

            // 设置图片渲染模式为模板模式，使其可以使用tintColor
            let templateImage = adaptedImage.withRenderingMode(.alwaysTemplate)
            iconView.image = templateImage
            iconView.tintColor = direction.toLevelColor

            // 添加到缓存（缓存原始图片，渲染模式在显示时设置）
            imageCache[imageName] = adaptedImage
        } else {
            // 图片加载失败，回退到SF Symbols
            setupFallbackIcon(for: direction)
        }
    }

    /// 根据方向获取对应的图片名称
    private func getImageName(for direction: SwipeDirection) -> String {
        switch direction {
        case .left: return "imcard_hard"
        case .right: return "imcard_easy"
        case .up: return "imcard_normal"
        case .down: return "imcard_again"
        }
    }

    /// 安全加载图片，处理边界条件
    private func loadImageSafely(named imageName: String) -> UIImage? {
        // 检查Bundle中是否存在该图片
        guard let image = UIImage(named: imageName) else {
            zcLog("警告：图片 '\(imageName)' 未找到，使用系统图标作为fallback")
            return nil
        }

        // 检查图片是否有效
        guard image.isValid else {
            zcLog("警告：图片 '\(imageName)' 无效，内存大小: \(image.memorySize) bytes")
            return nil
        }

        // 检查图片尺寸是否合理（避免极端尺寸）
        let maxDimension: CGFloat = 2048.0 // 最大允许尺寸
        guard image.size.width <= maxDimension && image.size.height <= maxDimension else {
            zcLog("警告：图片 '\(imageName)' 尺寸过大 (\(image.size.width)x\(image.size.height))，将进行缩放")
            return adaptImageForScreen(image: image)
        }

        // 检查图片内存大小是否过大（超过5MB）
        let maxMemorySize = 5 * 1024 * 1024 // 5MB
        if image.memorySize > maxMemorySize {
            zcLog("警告：图片 '\(imageName)' 内存占用过大 (\(image.memorySize) bytes)，将进行压缩")
            return compressImage(image: image)
        }

        return image
    }

    /// 压缩图片以减少内存占用
    private func compressImage(image: UIImage) -> UIImage? {
        let targetSize = CGSize(width: 256, height: 256)

        // 计算压缩比例
        let compressionRatio = min(targetSize.width / image.size.width, targetSize.height / image.size.height)

        // 如果压缩比例小于50%，则进行压缩
        guard compressionRatio < 0.5 else {
            return image
        }

        let compressedSize = CGSize(width: image.size.width * compressionRatio,
                                  height: image.size.height * compressionRatio)

        UIGraphicsBeginImageContextWithOptions(compressedSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: compressedSize))
        let compressedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return compressedImage
    }

    /// 根据屏幕尺寸适配图片大小
    private func adaptImageForScreen(image: UIImage) -> UIImage {
        let screenScale = UIScreen.main.scale
        let targetSize = CGSize(width: 64 * screenScale, height: 64 * screenScale)

        // 如果图片太大，进行缩放以节省内存
        if image.size.width > targetSize.width || image.size.height > targetSize.height {
            return image.scaled(to: targetSize)
        }

        return image
    }

    /// 设置fallback图标（使用SF Symbols）
    private func setupFallbackIcon(for direction: SwipeDirection) {
        switch direction {
        case .left:
            iconView.image = UIImage(systemName: "xmark.circle.fill")
        case .right:
            iconView.image = UIImage(systemName: "heart.circle.fill")
        case .up:
            iconView.image = UIImage(systemName: "message.circle.fill")
        case .down:
            iconView.image = UIImage(systemName: "arrow.down.circle.fill")
        }
    }

    private func setupConstraints() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false

        // 移除固定高度约束，使用内容自适应布局
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32 * 2),
            iconView.heightAnchor.constraint(equalToConstant: 32 * 2),

            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            // 确保容器高度足够容纳内容
            iconView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor)
        ])
    }

    /// CALayer takes concrete CGColors: UIKit cannot automatically update
    /// them when the user switches Light/Dark while a swipe is visible.
    /// Keep the original semantic UIColor as authority and resolve on traits.
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.hasDifferentColorAppearance(
            comparedTo: traitCollection) ?? true else { return }
        let resolved = adaptiveStrokeColor.resolvedColor(with: traitCollection).cgColor
        layer.borderColor = resolved
        layer.shadowColor = resolved
    }

    required init?(coder aDecoder: NSCoder)
    {
        return nil
    }

    deinit {
        // 清理缓存以释放内存
        clearImageCache()
    }

    /// 清理图片缓存
    private func clearImageCache() {
        imageCache.removeAll()
//        zcLog("图片缓存已清理，共释放 \(imageCache.count) 张图片的内存")
    }

    /// 内存警告时的处理
    func handleMemoryWarning() {
        clearImageCache()
    }

    /// 预加载所有图片到缓存（可选的性能优化）
    func preloadImages() {
        let directions: [SwipeDirection] = [.left, .right, .up, .down]

        for direction in directions {
            let imageName = getImageName(for: direction)
            if imageCache[imageName] == nil {
                if let image = loadImageSafely(named: imageName) {
                    let adaptedImage = adaptImageForScreen(image: image)
                    imageCache[imageName] = adaptedImage
                }
            }
        }

        zcLog("预加载完成，缓存中已有 \(imageCache.count) 张图片")
    }

    /// 获取缓存状态信息
    func getCacheInfo() -> (count: Int, totalMemory: Int) {
        let count = imageCache.count
        let totalMemory = imageCache.values.reduce(0) { $0 + $1.memorySize }
        return (count, totalMemory)
    }
}


/// V3 four-way swipe feedback. An opaque semantic-ink badge and strong
/// typographic hierarchy remain legible over the rotating/scrolled answer.
/// The underlying SwipeCardStack still controls fade/drag and FSRS semantics.
@MainActor
final class ImpressV3RatingOverlay: UIView {
    init(direction: SwipeDirection) {
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false

        let title: String
        let symbol: String
        switch direction {
        case .left:  title = V3L("困难"); symbol = "arrow.left"
        case .up:    title = V3L("良好"); symbol = "arrow.up"
        case .right: title = V3L("容易"); symbol = "arrow.right"
        case .down:  title = V3L("重来"); symbol = "arrow.down"
        }

        let badge = UIView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.backgroundColor = ImpressV3Appearance.reviewOverlaySurface(for: direction)
        badge.layer.cornerRadius = ImpressV3Appearance.Metrics.reviewOverlayBadgeHeight / 2
        badge.clipsToBounds = true

        let image = UIImageView(image: UIImage(systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: ImpressV3Appearance.Metrics.reviewOverlaySymbolSize,
                weight: .medium)))
        image.tintColor = ImpressV3Appearance.reviewOverlayInk(for: direction)
        image.contentMode = .scaleAspectFit

        let text = UILabel()
        text.text = title
        text.font = ImpressV3Appearance.Typography.ratingFeedback
        text.adjustsFontForContentSizeCategory = true
        text.textColor = ImpressV3Appearance.reviewOverlayInk(for: direction)
        text.textAlignment = .center

        let content = UIStackView(arrangedSubviews: [image, text])
        content.axis = .horizontal
        content.spacing = ImpressV3Appearance.Metrics.symbolGap
        content.alignment = .center
        content.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(content)
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: centerXAnchor),
            // A short-lived, non-interactive hint follows the visible card
            // centre even when answer content scrolls underneath it.
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.heightAnchor.constraint(greaterThanOrEqualToConstant:
                ImpressV3Appearance.Metrics.reviewOverlayBadgeHeight),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                constant: ImpressV3Appearance.Metrics.reviewOverlayEdgeInset),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                constant: -ImpressV3Appearance.Metrics.reviewOverlayEdgeInset),
            content.leadingAnchor.constraint(equalTo: badge.leadingAnchor,
                constant: ImpressV3Appearance.Metrics.reviewOverlayContentHInset),
            content.trailingAnchor.constraint(equalTo: badge.trailingAnchor,
                constant: -ImpressV3Appearance.Metrics.reviewOverlayContentHInset),
            content.topAnchor.constraint(equalTo: badge.topAnchor,
                constant: ImpressV3Appearance.Metrics.reviewOverlayContentVInset),
            content.bottomAnchor.constraint(equalTo: badge.bottomAnchor,
                constant: -ImpressV3Appearance.Metrics.reviewOverlayContentVInset),
            image.widthAnchor.constraint(equalToConstant:
                ImpressV3Appearance.Metrics.reviewOverlaySymbolSize),
            image.heightAnchor.constraint(equalToConstant:
                ImpressV3Appearance.Metrics.reviewOverlaySymbolSize)
        ])
        accessibilityLabel = title
        accessibilityTraits = .staticText
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
}
