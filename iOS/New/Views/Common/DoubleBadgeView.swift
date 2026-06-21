//
//  DoubleBadgeView.swift
//  Aidoku
//
//  Created by Skitty on 11/21/25.
//

import UIKit

class DoubleBadgeView: UIView {
    var badgeNumber: Int = 0 {
        didSet {
            updateText()
            updateLayout()
        }
    }

    var badgeNumber2: Int = 0 {
        didSet {
            updateText()
            updateLayout()
        }
    }

    var badgeImage: UIImage? {
        didSet {
            badgeImageView.image = badgeImage
            badgeImageView.isHidden = badgeImage == nil
            updateLayout()
        }
    }

    var badgeImage2: UIImage? {
        didSet {
            badgeImageView2.image = badgeImage2
            badgeImageView2.isHidden = badgeImage2 == nil
            updateLayout()
        }
    }

    var badgeTextOverride2: String? {
        didSet {
            updateText()
            updateLayout()
        }
    }

    private lazy var badgeView = {
        let badgeView = UIView()
        badgeView.isHidden = true
        badgeView.backgroundColor = tintColor
        badgeView.layer.cornerRadius = 5
        badgeView.addSubview(badgeStackView)
        return badgeView
    }()

    private lazy var badgeImageView = makeImageView()

    private let badgeLabel = {
        let badgeLabel = UILabel()
        badgeLabel.textColor = .white
        badgeLabel.numberOfLines = 1
        badgeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        return badgeLabel
    }()

    private lazy var badgeStackView = makeStackView(imageView: badgeImageView, label: badgeLabel)

    private lazy var badgeView2 = {
        let badgeView = UIView()
        badgeView.isHidden = true
        badgeView.backgroundColor = .systemIndigo
        badgeView.layer.cornerRadius = 5
        badgeView.addSubview(badgeStackView2)
        return badgeView
    }()

    private lazy var badgeImageView2 = makeImageView()

    private let badgeLabel2 = {
        let badgeLabel = UILabel()
        badgeLabel.textColor = .white
        badgeLabel.numberOfLines = 1
        badgeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        return badgeLabel
    }()

    private lazy var badgeStackView2 = makeStackView(imageView: badgeImageView2, label: badgeLabel2)

    private var badgeConstraints: [NSLayoutConstraint] = []

    override var intrinsicContentSize: CGSize {
        var width: CGFloat = 0
        if !badgeView.isHidden {
            width += badgeWidth(label: badgeLabel, imageView: badgeImageView)
        }
        if !badgeView2.isHidden {
            width += badgeWidth(label: badgeLabel2, imageView: badgeImageView2)
        }
        return CGSize(width: width, height: 20)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
        constrain()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure() {
        addSubview(badgeView)
        addSubview(badgeView2)
    }

    func constrain() {
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeStackView.translatesAutoresizingMaskIntoConstraints = false
        badgeView2.translatesAutoresizingMaskIntoConstraints = false
        badgeStackView2.translatesAutoresizingMaskIntoConstraints = false

        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgeLabel2.setContentHuggingPriority(.required, for: .horizontal)
        badgeLabel2.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            badgeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            badgeView.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeView.widthAnchor.constraint(equalTo: badgeStackView.widthAnchor, constant: 10),
            badgeView.heightAnchor.constraint(equalToConstant: 20),
            badgeStackView.centerXAnchor.constraint(equalTo: badgeView.centerXAnchor),
            badgeStackView.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),

            badgeView2.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeView2.widthAnchor.constraint(equalTo: badgeStackView2.widthAnchor, constant: 10),
            badgeView2.heightAnchor.constraint(equalToConstant: 20),
            badgeStackView2.centerXAnchor.constraint(equalTo: badgeView2.centerXAnchor),
            badgeStackView2.centerYAnchor.constraint(equalTo: badgeView2.centerYAnchor)
        ])

        updateLayout()
    }

    override func tintColorDidChange() {
        badgeView.backgroundColor = tintColor
        if tintAdjustmentMode == .dimmed {
            badgeView2.backgroundColor = .systemIndigo.grayscale()
        } else {
            badgeView2.backgroundColor = .systemIndigo
        }
    }

    func updateLayout() {
        NSLayoutConstraint.deactivate(badgeConstraints)
        if badgeNumber > 0 && badgeNumber2 > 0 {
            // both badges visible, show side by side
            badgeView.isHidden = false
            badgeView2.isHidden = false
            badgeView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner] // top-left, bottom-left
            badgeView2.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner] // top-right, bottom-right
            badgeConstraints = [
                badgeView2.leadingAnchor.constraint(equalTo: badgeView.trailingAnchor)
            ]
        } else if badgeNumber > 0 {
            // only first badge visible
            badgeView.isHidden = false
            badgeView2.isHidden = true
            badgeView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            badgeConstraints = [
                badgeView2.leadingAnchor.constraint(equalTo: leadingAnchor)
            ]
        } else if badgeNumber2 > 0 {
            // only second badge visible
            badgeView.isHidden = true
            badgeView2.isHidden = false
            badgeView2.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            badgeConstraints = [
                badgeView2.leadingAnchor.constraint(equalTo: leadingAnchor)
            ]
        } else {
            badgeView.isHidden = true
            badgeView2.isHidden = true
            badgeConstraints = [
                badgeView2.leadingAnchor.constraint(equalTo: leadingAnchor)
            ]
        }
        NSLayoutConstraint.activate(badgeConstraints)
        invalidateIntrinsicContentSize()
    }

    private func updateText() {
        badgeLabel.text = badgeNumber == 0 ? nil : String(badgeNumber)
        badgeLabel2.text = badgeNumber2 == 0 ? nil : badgeTextOverride2 ?? String(badgeNumber2)
    }

    private func makeImageView() -> UIImageView {
        let imageView = UIImageView()
        imageView.isHidden = true
        imageView.tintColor = .white
        imageView.contentMode = .scaleAspectFit
        imageView.preferredSymbolConfiguration = .init(pointSize: 10, weight: .semibold)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalToConstant: 11).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 11).isActive = true
        return imageView
    }

    private func makeStackView(imageView: UIImageView, label: UILabel) -> UIStackView {
        let stackView = UIStackView(arrangedSubviews: [imageView, label])
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 3
        return stackView
    }

    private func badgeWidth(label: UILabel, imageView: UIImageView) -> CGFloat {
        let textWidth = label.text?.size(withAttributes: [.font: label.font as Any]).width ?? 0
        let imageWidth: CGFloat = imageView.isHidden ? 0 : 11
        let spacing: CGFloat = imageWidth > 0 && textWidth > 0 ? 3 : 0
        return textWidth + imageWidth + spacing + 10
    }
}

private extension UIColor {
    /// Returns a grayscale version of the color.
    func grayscale() -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return self }

        let gray = red * 0.299 + green * 0.587 + blue * 0.114
        return UIColor(red: gray, green: gray, blue: gray, alpha: alpha)
    }
}
