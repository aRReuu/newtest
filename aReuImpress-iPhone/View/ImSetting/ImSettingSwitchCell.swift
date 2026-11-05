//
//  ImSettingSwitchCell.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 10/5/25.
//

import UIKit

class ImSettingSwitchCell: UITableViewCell {

    static let identifier = "ImSettingSwitchCell"

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 16)
        label.textColor = titleColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    let settingSwitch: UISwitch = {
        let switchControl = UISwitch()
        switchControl.translatesAutoresizingMaskIntoConstraints = false
        return switchControl
    }()

    var switchValueChanged: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        contentView.addSubview(titleLabel)
        contentView.addSubview(settingSwitch)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(greaterThanOrEqualTo: settingSwitch.leadingAnchor, constant: -16),

            settingSwitch.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            settingSwitch.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])

        settingSwitch.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)

        selectionStyle = .none
    }

    func configure(title: String, isOn: Bool) {
        titleLabel.text = title
        settingSwitch.isOn = isOn
    }

    @objc private func switchChanged(_ sender: UISwitch) {
        switchValueChanged?(sender.isOn)
    }
}
