//
//  TabBarController.swift
//  Aidoku
//
//  Created by Skitty on 7/26/25.
//

import Combine
import SwiftUI
import SwiftUIIntrospect

class TabBarController: UITabBarController {
    private let tabSelectionFeedback = UISelectionFeedbackGenerator()
    private var libraryBarCollapsed = false
    private weak var chromeScrollView: UIScrollView?
    private var chromeTranslation: CGFloat = 0
    private var chromeDistance: CGFloat = 0
    private weak var chromeMenuView: UIView?
    private weak var chromeSearchView: UIView?
    private var chromeMenuFrame = CGRect.zero
    private var chromeSearchFrame = CGRect.zero
    private var chromeAnimator: UIViewPropertyAnimator?
    private var chromeAnimatorCollapsing = true

    private func updateChromeParts() {
        guard !libraryBarCollapsed, chromeAnimator == nil, !tabBar.isHidden,
              UIDevice.current.userInterfaceIdiom == .phone else { return }
        // Keep UIKit's real search control, glass and symbol untouched. Only the
        // separate, wide tab platter moves. If UIKit changes this layout, leave it expanded.
        let parts = tabBar.subviews.filter { !$0.isHidden && $0.alpha > 0.99 }
        guard let menu = parts.filter({ $0.bounds.width > 120 && (40...90).contains($0.bounds.height) })
                .max(by: { $0.bounds.width < $1.bounds.width }),
              let search = parts.first(where: {
                  (44...90).contains($0.bounds.width) && (44...90).contains($0.bounds.height)
                      && $0.frame.minX >= menu.frame.maxX && abs($0.frame.midY - menu.frame.midY) < 2
              }) else { return }
        chromeMenuView = menu
        chromeSearchView = search
        chromeMenuFrame = menu.frame
        chromeSearchFrame = search.frame
        // The contracting platter passes behind the original search control.
        tabBar.bringSubviewToFront(search)
    }

    private func observeActiveChromeScroll() {
        guard #available(iOS 26.0, *), UIDevice.current.userInterfaceIdiom == .phone else { return }
        var rootVisible = selectedViewController !== searchNavigationController
        if let nav = selectedViewController as? UINavigationController { rootVisible = rootVisible && nav.viewControllers.count == 1 }
        if selectedIndex == 3, let nav = settingsPath?.navigationController { rootVisible = rootVisible && nav.viewControllers.count == 1 }
        let next = rootVisible ? selectedViewController?.view.firstScrollView() : nil
        if next !== chromeScrollView {
            chromeScrollView?.panGestureRecognizer.removeTarget(self, action: #selector(chromePanChanged(_:)))
            chromeScrollView = next
            chromeScrollView?.panGestureRecognizer.addTarget(self, action: #selector(chromePanChanged(_:)))
            chromeDistance = 0
        }
        if !rootVisible { setLibraryBarCollapsed(false, animated: false) }
    }

    @objc private func chromePanChanged(_ pan: UIPanGestureRecognizer) {
        guard let scroll = chromeScrollView else { return }
        let translation = pan.translation(in: scroll).y
        defer { chromeTranslation = translation }
        if pan.state == .began { chromeDistance = 0; return }
        guard pan.state == .changed else { chromeDistance = 0; return }
        if let nav = selectedViewController as? UINavigationController, nav.topViewController?.isEditing == true { return }
        let top = -scroll.adjustedContentInset.top
        let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        guard bottom - top > 40 else { return }
        if scroll.contentOffset.y <= top + 4 { setLibraryBarCollapsed(false); chromeDistance = 0; return }
        let delta = chromeTranslation - translation
        if delta * chromeDistance < 0 { chromeDistance = 0 }
        chromeDistance += delta
        if abs(chromeDistance) > 28 { setLibraryBarCollapsed(chromeDistance > 0); chromeDistance = 0 }
    }

    func setLibraryBarCollapsed(_ collapsed: Bool, animated: Bool = true) {
        guard #available(iOS 26.0, *) else { return }
        if !animated || UIAccessibility.isReduceMotionEnabled {
            chromeAnimator?.stopAnimation(true)
            chromeAnimator = nil
        } else if libraryBarCollapsed == collapsed { return }
        if collapsed, !libraryBarCollapsed { updateChromeParts() }
        guard let menu = chromeMenuView, chromeSearchView != nil, chromeMenuFrame.width > 0 else { return }
        libraryBarCollapsed = collapsed
        menu.isUserInteractionEnabled = !collapsed
        menu.accessibilityElementsHidden = collapsed

        let target = CGAffineTransform(
            translationX: chromeSearchFrame.midX - chromeMenuFrame.midX,
            y: chromeSearchFrame.midY - chromeMenuFrame.midY
        ).scaledBy(x: chromeSearchFrame.width / chromeMenuFrame.width, y: 1)
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            menu.transform = collapsed ? target : .identity
            menu.alpha = collapsed ? 0 : 1
            return
        }
        // Reversing a gesture reverses the same animation from its current frame.
        if let animator = chromeAnimator {
            animator.isReversed = collapsed != chromeAnimatorCollapsing
            return
        }
        // Fresh transitions ease out in either direction; in-flight ones reverse in place.
        let animator = UIViewPropertyAnimator(duration: 0.28, curve: .easeOut)
        chromeAnimator = animator
        chromeAnimatorCollapsing = collapsed
        animator.addAnimations { menu.transform = collapsed ? target : .identity }
        animator.addAnimations({ menu.alpha = collapsed ? 0 : 1 }, delayFactor: collapsed ? 0.65 : 0)
        animator.addCompletion { [weak self, weak animator] _ in
            guard let self, self.chromeAnimator === animator else { return }
            self.chromeAnimator = nil
            menu.transform = self.libraryBarCollapsed ? target : .identity
            menu.alpha = self.libraryBarCollapsed ? 0 : 1
        }
        animator.startAnimation()
    }

    private var originalFrame: CGRect = .zero
    private var shrunkFrame: CGRect = .zero
    private var cancellables: [AnyCancellable] = []

    private var settingsPath: NavigationCoordinator?
    private var previousSelectedIndex: Int?

    private weak var historyNavigationController: UINavigationController?
    private weak var searchNavigationController: UINavigationController?

    private let searchController = SearchViewController()

    private lazy var libraryProgressView = CircularProgressView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))

    private lazy var libraryRefreshAccessory: UIView = {
        let view = UIView()

        let label = UILabel()
        label.text = NSLocalizedString("REFRESHING_LIBRARY")
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        libraryProgressView.radius = 12
        libraryProgressView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(libraryProgressView)

        if #unavailable(iOS 26) {
            // add styling for older versions without the bottom accessory view
            let backgroundView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
            backgroundView.layer.cornerRadius = 48 / 2
            backgroundView.layer.borderColor = UIColor.quaternarySystemFill.cgColor
            backgroundView.layer.borderWidth = 1
            backgroundView.clipsToBounds = true
            backgroundView.translatesAutoresizingMaskIntoConstraints = false
            view.insertSubview(backgroundView, at: 0)

            NSLayoutConstraint.activate([
                backgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                backgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                backgroundView.topAnchor.constraint(equalTo: view.topAnchor),
                backgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: libraryProgressView.leadingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.heightAnchor.constraint(equalToConstant: 48),

            libraryProgressView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            libraryProgressView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            libraryProgressView.widthAnchor.constraint(equalToConstant: 20),
            libraryProgressView.heightAnchor.constraint(equalToConstant: 20)
        ])

        return view
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        delegate = self
        Task { await PrivacyDisplayStore.shared.refreshKnownRatings() }

        let libraryViewController = NavigationController(rootViewController: LibraryViewController())
        let browseViewController = NavigationController(rootViewController: BrowseViewController())
        let searchViewController = NavigationController(rootViewController: searchController)
        searchNavigationController = searchViewController

        let historyPath = NavigationCoordinator(rootViewController: nil)
        let historyHostingController = UIHostingController(rootView: HistoryView()
            .environmentObject(historyPath))
        historyPath.rootViewController = historyHostingController
        let historyViewController = NavigationController(rootViewController: historyHostingController)
        historyNavigationController = historyViewController

        let settingsPath = NavigationCoordinator(rootViewController: nil)
        let settingsViewController: UIViewController
        if #available(iOS 26.0, *), UIDevice.current.userInterfaceIdiom != .pad {
            settingsViewController = UIHostingController(
                rootView: NavigationStack {
                    SettingsView()
                        .environmentObject(settingsPath)
                }.introspect(.navigationStack, on: .iOS(.v26, .v27)) { entity in
                    settingsPath.rootViewController = entity
                }
            )
        } else {
            // this breaks the zoom transitions from the toolbar buttons in the backups setting page on ios 18 / ipads
            let hosting = UIHostingController(rootView: SettingsView().environmentObject(settingsPath))
            let entity = NavigationController(rootViewController: hosting)
            entity.navigationBar.prefersLargeTitles = true
            settingsPath.rootViewController = entity
            settingsViewController = entity
        }
        self.settingsPath = settingsPath

        libraryViewController.navigationBar.prefersLargeTitles = true
        browseViewController.navigationBar.prefersLargeTitles = true
        historyViewController.navigationBar.prefersLargeTitles = true
        searchViewController.navigationBar.prefersLargeTitles = true

        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior = .never
            let searchTab = UISearchTab { _ in
                searchViewController
            }
            searchTab.automaticallyActivatesSearch = true
            let fixedTabs = [
                UITab(
                    title: NSLocalizedString("LIBRARY"),
                    image: UIImage(systemName: "books.vertical.fill"),
                    identifier: "0"
                ) { _ in
                    libraryViewController
                },
                UITab(
                    title: NSLocalizedString("BROWSE"),
                    image: UIImage(systemName: "globe"),
                    identifier: "1"
                ) { _ in
                    browseViewController
                },
                UITab(
                    title: NSLocalizedString("HISTORY"),
                    image: UIImage(systemName: "clock.fill"),
                    identifier: "2"
                ) { _ in
                    historyViewController
                },
                UITab(
                    title: NSLocalizedString("SETTINGS"),
                    image: UIImage(systemName: "gear"),
                    identifier: "3"
                ) { _ in
                    settingsViewController
                }
            ]
            fixedTabs.forEach {
                $0.allowsHiding = false
                $0.preferredPlacement = .fixed
            }
            tabs = fixedTabs + [searchTab]
        } else {
            libraryViewController.tabBarItem = UITabBarItem(
                title: NSLocalizedString("LIBRARY"),
                image: UIImage(systemName: "books.vertical.fill"),
                tag: 0
            )
            browseViewController.tabBarItem = UITabBarItem(
                title: NSLocalizedString("BROWSE"),
                image: UIImage(systemName: "globe"),
                tag: 1
            )
            historyViewController.tabBarItem = UITabBarItem(
                tabBarSystemItem: .history,
                tag: 2
            )
            searchViewController.tabBarItem = UITabBarItem(
                tabBarSystemItem: .search,
                tag: 3
            )
            settingsViewController.tabBarItem = UITabBarItem(
                title: NSLocalizedString("SETTINGS"),
                image: UIImage(systemName: "gear"),
                tag: 4
            )
            viewControllers = [
                libraryViewController,
                browseViewController,
                historyViewController,
                searchViewController,
                settingsViewController
            ]
        }

        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance


        let updateCount = AppSettings.browse.updateCount.get()
        browseViewController.tabBarItem.badgeValue = updateCount > 0 ? String(updateCount) : nil

        NotificationCenter.default.publisher(for: .init(AppSettings.general.incognitoMode.key))
            .sink { [weak self] _ in
                self?.setLibraryBarCollapsed(false, animated: false)
                self?.updateFrame(animated: true)
            }
            .store(in: &cancellables)
    }

    func updateFrame(animated: Bool = false) {
        if originalFrame == .zero {
            let bannerHeight = (UIApplication.shared.connectedScenes.first?.delegate as? SceneDelegate)?.totalBannerHeight ?? 0
            originalFrame = view.frame
            shrunkFrame = .init(
                x: originalFrame.origin.x,
                y: originalFrame.origin.y + bannerHeight,
                width: originalFrame.width,
                height: originalFrame.height - bannerHeight
            )
        }
        func commit() {
            if AppSettings.general.incognitoMode.get() {
                view.frame = shrunkFrame
            } else {
                view.frame = originalFrame
            }
        }
        if animated {
            UIView.animate(withDuration: CATransaction.animationDuration()) {
                commit()
            }
        } else {
            commit()
        }
    }
}

extension TabBarController {
    func search(for query: String) {
        if #available(iOS 26.0, *) {
            selectedTab = tabs.last
        } else {
            selectedViewController = searchNavigationController
        }

        searchNavigationController?.popToRootViewController(animated: false)
        searchController.search(for: query)
    }

    func showLibraryRefreshView() {
        libraryProgressView.setProgress(value: 0, withAnimation: false)

        if #available(iOS 26.0, *) {
            setBottomAccessory(.init(contentView: libraryRefreshAccessory), animated: true)
        } else {
            libraryRefreshAccessory.layer.opacity = 0
            view.insertSubview(libraryRefreshAccessory, belowSubview: tabBar)
            UIView.animate(withDuration: 0.5) {
                self.libraryRefreshAccessory.layer.opacity = 1
            }
        }
    }

    func setLibraryRefreshProgress(_ progress: Float) {
        libraryProgressView.setProgress(value: progress, withAnimation: true)
    }

    func hideAccessoryView() {
        if #available(iOS 26.0, *) {
            setBottomAccessory(nil, animated: true)
        } else {
            UIView.animate(withDuration: 0.5) {
                self.libraryRefreshAccessory.layer.opacity = 0
            } completion: { _ in
                self.libraryRefreshAccessory.removeFromSuperview()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if #available(iOS 26.0, *) {
            updateChromeParts()
            observeActiveChromeScroll()
        }
        if #unavailable(iOS 26.0) {
            let height: CGFloat = 48
            let padding: CGFloat = 16

            libraryRefreshAccessory.frame = CGRect(
                x: tabBar.frame.origin.x + view.safeAreaInsets.left + padding,
                y: tabBar.frame.origin.y - height - padding / 2,
                width: tabBar.frame.width - padding * 2 - view.safeAreaInsets.left - view.safeAreaInsets.right,
                height: height
            )
        }
        updateFrame()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        setLibraryBarCollapsed(false, animated: false)
        chromeMenuFrame = .zero
        chromeSearchFrame = .zero
        super.viewWillTransition(to: size, with: coordinator)
        originalFrame = .init(origin: self.originalFrame.origin, size: size)
        shrunkFrame = self.originalFrame
        coordinator.animate { _ in
            self.view.setNeedsLayout()
        } completion: { _ in
            let bannerHeight = (UIApplication.shared.connectedScenes.first?.delegate as? SceneDelegate)?.totalBannerHeight ?? 0
            self.shrunkFrame = .init(
                x: self.originalFrame.origin.x,
                y: self.originalFrame.origin.y + bannerHeight,
                width: self.originalFrame.width,
                height: self.originalFrame.height - bannerHeight
            )
            self.updateFrame(animated: true)
        }
    }
}

extension TabBarController: UITabBarControllerDelegate {
    @available(iOS 18.0, *)
    func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
        setLibraryBarCollapsed(false, animated: false)
        DispatchQueue.main.async { self.observeActiveChromeScroll() }
        checkForSettingsPop()
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        if #unavailable(iOS 18.0) {
            checkForSettingsPop()
        }
    }

    @available(iOS 18.0, *)
    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        if #available(iOS 26.0, *) {
            tabSelectionFeedback.selectionChanged()
            tabSelectionFeedback.prepare()
            PrivacyDisplayStore.shared.libraryTabTapped(isLibrary: tab.identifier == "0")
        }
        if tab === tabBarController.selectedTab {
            checkForHistoryReselection()
        }
        return true
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if #unavailable(iOS 26.0) {
            tabSelectionFeedback.selectionChanged()
            tabSelectionFeedback.prepare()
            PrivacyDisplayStore.shared.libraryTabTapped(isLibrary: viewController.tabBarItem.tag == 0)
        }
        if viewController === selectedViewController {
            checkForHistoryReselection()
        }
        return true
    }

    // when the history tab is selected while it's already showing the top of the history list,
    // let the history view know so that it can continue reading the last opened manga
    private func checkForHistoryReselection() {
        guard
            AppSettings.library.continueReadingOnReselect.get(),
            let historyNavigationController,
            selectedViewController === historyNavigationController,
            // if there's anything pushed on top, the default behavior pops back to the history list
            historyNavigationController.viewControllers.count == 1,
            // if the list isn't at the top, the default behavior scrolls it there
            let scrollView = historyNavigationController.topViewController?.view.firstScrollView(),
            scrollView.isScrolledToTop
        else { return }
        NotificationCenter.default.post(name: .historyTabReselected, object: nil)
    }

    private func checkForSettingsPop() {
        let settingsIndex: Int
        if #available(iOS 26.0, *) {
            settingsIndex = 3
        } else {
            settingsIndex = 4
        }
        if selectedIndex == previousSelectedIndex && previousSelectedIndex == settingsIndex {
            settingsPath?.navigationController?.popToRootViewController(animated: true)
        }
        previousSelectedIndex = selectedIndex
    }
}

// MARK: - Keyboard Shortcuts
extension TabBarController {
    override var keyCommands: [UIKeyCommand]? {
        tabBar.items?.enumerated().map { index, item in
            UIKeyCommand(
                title: item.title ?? "Tab \(index + 1)",
                action: #selector(selectTab),
                input: "\(index + 1)",
                modifierFlags: .shiftOrCommand,
                alternates: [],
                attributes: [],
                state: .off
            )
        }
    }

    @objc private func selectTab(sender: UIKeyCommand) {
        guard
            let input = sender.input,
            let newIndex = Int(input),
            newIndex >= 1 && newIndex <= (tabBar.items?.count ?? 0)
        else { return }
        selectedIndex = newIndex - 1
    }

    override var canBecomeFirstResponder: Bool { true }
}
