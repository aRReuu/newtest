import UIKit

/// Use system-owned navigation chrome (including iOS 26/27 Liquid Glass).
/// No transparent-background hacks: UIKit chooses materials, contrast and spacing.
class ImNavigationViewController: UINavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationBar.prefersLargeTitles = true
        ImpressV3Appearance.styleNavigationBar(navigationBar)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // UIKit may recreate bars when a modal or appearance mode changes.
        ImpressV3Appearance.styleNavigationBar(navigationBar)
    }

    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        if !children.isEmpty {
            viewController.hidesBottomBarWhenPushed = true
        }
        super.pushViewController(viewController, animated: animated)
    }
}
