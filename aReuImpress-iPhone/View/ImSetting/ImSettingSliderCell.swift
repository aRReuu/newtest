//
//  ImSettingSliderCell.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 10/5/25.
//

import UIKit

enum SliderUnitType {
    case hours    // 每X小时
    case cards    // X张卡片
    case time     // 时间类型（分钟/小时）
}

class ImSettingSliderCell: UITableViewCell {

    static let identifier = "ImSettingSliderCell"

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.textColor = titleColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let valueLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .subheadline)
        label.textColor = contentColor
        label.textAlignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    let slider: UISlider = {
        let slider = UISlider()
        slider.minimumTrackTintColor = funBtnColor
        slider.maximumTrackTintColor = subTitleColor.withAlphaComponent(highlightAlpha)
        slider.translatesAutoresizingMaskIntoConstraints = false
        return slider
    }()

    var sliderValueChanged: ((CGFloat) -> Void)?
    private var unitType: SliderUnitType = .hours

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        contentView.addSubview(titleLabel)
        contentView.addSubview(valueLabel)
        contentView.addSubview(slider)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(greaterThanOrEqualTo: valueLabel.leadingAnchor, constant: -16),

            valueLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            valueLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            slider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            slider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            slider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        ])

        slider.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)

        selectionStyle = .none
    }

    func configure(title: String, currentValue: CGFloat, minValue: CGFloat, maxValue: CGFloat, unitType: SliderUnitType = .hours) {
        titleLabel.text = title
        slider.minimumValue = Float(minValue)
        slider.maximumValue = Float(maxValue)
        slider.value = Float(currentValue)
        self.unitType = unitType
        updateValueLabel()
    }

    private func updateValueLabel() {
        switch unitType {
        case .hours:
            let hours = round(slider.value * 2) / 2  // 0.5为步长
            if hours == 1 {
                valueLabel.text = "每小时"
            } else {
                valueLabel.text = String(format: "每%.1f小时", hours)
            }
        case .cards:
            let cards = Int(round(slider.value))  // 整数步长
            valueLabel.text = "\(cards)张卡片"
        case .time:
            let minutes = Int(round(slider.value))
            if minutes >= 60 {
                let hours = Double(minutes) / 60.0
                valueLabel.text = String(format: "%.1f小时", hours)
            } else {
                valueLabel.text = "\(minutes)分钟"
            }
        }
    }

    @objc private func sliderChanged(_ sender: UISlider) {
        updateValueLabel()
        switch unitType {
        case .hours:
            let roundedValue = round(sender.value * 2) / 2
            sender.value = roundedValue
            sliderValueChanged?(CGFloat(roundedValue))
        case .cards:
            let roundedValue = round(sender.value)
            sender.value = roundedValue
            sliderValueChanged?(CGFloat(roundedValue))
        case .time:
            let roundedValue = round(sender.value)
            sender.value = roundedValue
            sliderValueChanged?(CGFloat(roundedValue))
        }
    }
}
