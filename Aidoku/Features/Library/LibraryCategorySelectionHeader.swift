//
//  LibraryCategorySelectionHeader.swift
//  Aidoku
//
//  Created by Skitty on 2/25/26.
//

import UIKit

// based on MangaListSelectionHeaderDelegate

protocol LibraryCategorySelectionHeaderDelegate: AnyObject {
    func optionSelected(_ indexPath: IndexPath)
}

class LibraryCategorySelectionHeader: UICollectionReusableView {
    weak var delegate: LibraryCategorySelectionHeaderDelegate?

    struct Section {
        var title: String?
        var options: [String] = []
    }
    var options: [Section] = [] {
        didSet { updateMenu() }
    }
    var lockedOptions: [IndexPath] = [] {
        didSet { updateMenu() }
    }

    private let titleLabel = UILabel()
    private let menuButton = UIButton(type: .roundedRect)

    var selectionMenu: UIMenu? { menuButton.menu }
    var selectionTitle: String? { menuButton.currentTitle }

    private var selectedSection: Int = 0
    private var selectedOption: Int = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
        constrain()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure() {
        menuButton.tintColor = .label
        menuButton.setImage(
            UIImage(
                systemName: "chevron.down.circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17).applying(UIImage.SymbolConfiguration(paletteColors: [.secondaryLabel, .tertiarySystemFill]))
            ),
            for: .normal
        )

        // Move chevron to right side
        menuButton.configuration = .plain()
        menuButton.configuration?.imagePadding = 8
        menuButton.configuration?.imagePlacement = .trailing
        menuButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 10)
        menuButton.configuration?.baseForegroundColor = .label
        menuButton.configuration?.background.backgroundColor = .clear
        menuButton.configuration?.background.cornerRadius = 18
        menuButton.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes
            result.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
            return result
        }
        menuButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        updateMenu()
        menuButton.showsMenuAsPrimaryAction = true
        addSubview(menuButton)
    }

    func constrain() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        menuButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            menuButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            menuButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuButton.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            menuButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ])
    }

    func updateMenu() {
        var menus: [UIMenuElement] = []
        for (i, section) in options.enumerated() {
            var children: [UIAction] = []
            for (j, option) in section.options.enumerated() {
                let indexPath = IndexPath(row: j, section: i)
                let selected = selectedSection == i && selectedOption == j
                children.append(
                    UIAction(
                        title: option,
                        image: lockedOptions.contains(indexPath) ? UIImage(systemName: "lock.fill") : nil,
                        state: selected ? .on : .off
                    ) { _ in
                        self.setSelectedOption(indexPath)
                    }
                )
            }
            menus.append(UIMenu(title: section.title ?? "", options: .displayInline, children: children))
        }
        let menu = UIMenu(children: menus)
        menuButton.menu = menu

        let title = selectedSection == 0 && selectedOption == 0
            ? NSLocalizedString("LIBRARY")
            : options[safe: selectedSection]?.options[safe: selectedOption] ?? ""
        menuButton.setTitle(title, for: .normal)
    }

    func setSelectedOption(_ indexPath: IndexPath) {
        guard selectedSection != indexPath.section || selectedOption != indexPath.row else {
            return
        }
        selectedSection = indexPath.section
        selectedOption = indexPath.row
        updateMenu()
        delegate?.optionSelected(indexPath)
    }
}
