import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let win = UIWindow(frame: UIScreen.main.bounds)
        win.backgroundColor = Theme.background

        // Tab 1: Chat (conversation list -> chat). More tabs slot in here later.
        let chatNav = UINavigationController(rootViewController: ConversationListVC())
        chatNav.navigationBar.barStyle = .black
        chatNav.tabBarItem = UITabBarItem(title: "Chat", image: nil, tag: 0)
        // With no icon the caption sits low (where a label goes under an icon);
        // nudge it up so a title-only tab reads centered.
        chatNav.tabBarItem.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: -14)

        let tabs = UITabBarController()
        // UITabBar.barStyle is iOS 7+ — sending it on iOS 6 is an unrecognized selector
        // (crash at launch). iOS 6 tab bars are dark by default, so skipping it is fine.
        if tabs.tabBar.responds(to: #selector(setter: UITabBar.barStyle)) {
            tabs.tabBar.barStyle = .black
        }
        tabs.viewControllers = [chatNav]

        win.rootViewController = tabs
        win.makeKeyAndVisible()
        window = win
        return true
    }
}

// Shared dark palette.
enum Theme {
    static let background = UIColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
    static let rowBackground = UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
    static let inputBackground = UIColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1)
    static let fieldBackground = UIColor(red: 0.20, green: 0.20, blue: 0.23, alpha: 1)
    static let userBubble = UIColor(red: 0.20, green: 0.52, blue: 0.96, alpha: 1)
    static let assistantBubble = UIColor(red: 0.22, green: 0.22, blue: 0.25, alpha: 1)
    static let accent = UIColor(red: 0.20, green: 0.52, blue: 0.96, alpha: 1)
    static let primaryText = UIColor.white
    static let secondaryText = UIColor(red: 0.62, green: 0.62, blue: 0.66, alpha: 1)
}
