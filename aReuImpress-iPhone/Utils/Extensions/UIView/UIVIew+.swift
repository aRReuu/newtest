//
//  UIVIew+.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 7/10/25.
//

import UIKit


extension UIView
{
    @discardableResult
    func anchor(top: NSLayoutYAxisAnchor? = nil,
                left: NSLayoutXAxisAnchor? = nil,
                bottom: NSLayoutYAxisAnchor? = nil,
                right: NSLayoutXAxisAnchor? = nil,
                paddingTop: CGFloat = 0,
                paddingLeft: CGFloat = 0,
                paddingBottom: CGFloat = 0,
                paddingRight: CGFloat = 0,
                width: CGFloat = 0,
                height: CGFloat = 0) -> [NSLayoutConstraint] {
      translatesAutoresizingMaskIntoConstraints = false

      var anchors = [NSLayoutConstraint]()

      if let top = top {
        anchors.append(topAnchor.constraint(equalTo: top, constant: paddingTop))
      }
      if let left = left {
        anchors.append(leftAnchor.constraint(equalTo: left, constant: paddingLeft))
      }
      if let bottom = bottom {
        anchors.append(bottomAnchor.constraint(equalTo: bottom, constant: -paddingBottom))
      }
      if let right = right {
        anchors.append(rightAnchor.constraint(equalTo: right, constant: -paddingRight))
      }
      if width > 0 {
        anchors.append(widthAnchor.constraint(equalToConstant: width))
      }
      if height > 0 {
        anchors.append(heightAnchor.constraint(equalToConstant: height))
      }

      anchors.forEach { $0.isActive = true }

      return anchors
    }
}


// MARK: frame扩展
extension UIView
{
    var cq_x: CGFloat {
        get {
            return frame.origin.x
        }
        set {
            var f = frame
            f.origin.x = newValue
            frame = f
        }
    }
    
    var cq_y: CGFloat {
        get {
            return frame.origin.y
        }
        set {
            var f = frame
            f.origin.y = newValue
            frame = f
        }
    }
    
    var cq_centerX: CGFloat {
        get {
            return center.x
        }
        set {
            center = CGPoint(x: newValue, y: center.y)
        }
    }
    
    var cq_centerY: CGFloat {
        get {
            return center.y
        }
        set {
            center = CGPoint(x: center.x, y: newValue)
        }
    }
    
    var cq_width: CGFloat {
        get {
            return frame.size.width
        }
        set {
            var f = frame
            f.size.width = newValue
            frame = f
        }
    }
    
    var cq_height: CGFloat {
        get {
            return frame.size.height
        }
        set {
            var f = frame
            f.size.height = newValue
            frame = f
        }
    }
    
    var cq_size: CGSize {
        get {
            return frame.size
        }
        set {
            var f = frame
            f.size = newValue
            frame = f
        }
    }
    
    var cq_right: CGFloat {
        get {
            return frame.origin.x + frame.size.width
        }
        set {
            var f = frame
            f.origin.x = newValue - f.size.width
            frame = f
        }
    }
    
    var cq_bottom: CGFloat {
        get {
            return frame.origin.y + frame.size.height
        }
        set {
            var f = frame
            f.origin.y = newValue - f.size.height
            frame = f
        }
    }
}

// MARK: - RoundCorner扩展
extension UIView
{
    
    /// 设置默认圆角，圆角半径为视图高度的一半
    func setDefaultCorner() {
        updateCorner(cornerRadius: cq_height / 2)
    }
    
    /// 设置圆角半径
    /// - Parameter cornerRadius: 圆角半径
    func setCorner(_ cornerRadius: CGFloat) {
        updateCorner(cornerRadius: cornerRadius)
    }
    
    private func updateCorner(cornerRadius: CGFloat) {
        layer.masksToBounds = true
        layer.cornerRadius = cornerRadius
    }
    
    /// 设置圆角、边框宽度和边框颜色
    /// - Parameters:
    ///   - cornerRadius: 圆角半径
    ///   - width: 边框宽度
    ///   - color: 边框颜色
    func setCorner(_ cornerRadius: CGFloat, borderWidth width: CGFloat, borderColor color: UIColor) {
        layer.cornerRadius = cornerRadius
        layer.borderWidth = width
        layer.borderColor = color.cgColor
        layer.masksToBounds = true
    }
    
    /// 设置默认阴影
    func setShadow() {
        layer.masksToBounds = false
        layer.shadowOpacity = 0.15
        layer.shadowColor = UIColor.darkGray.cgColor
        layer.shadowRadius = 7.0
        layer.shadowOffset = CGSize(width: 0, height: 7)
    }
    
    /// 设置自定义颜色阴影
    /// - Parameter shadowColor: 阴影颜色
    func setShadow(_ shadowColor: UIColor) {
        layer.masksToBounds = false
        layer.shadowOpacity = 0.1
        layer.shadowColor = shadowColor.cgColor
        layer.shadowRadius = 8.0
        layer.shadowOffset = CGSize(width: 0, height: 8)
    }
}
