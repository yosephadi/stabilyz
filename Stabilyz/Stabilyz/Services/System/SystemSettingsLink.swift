import Foundation
import UIKit

/// Opens this app's page in the system Settings (docs/07 §7.6).
///
/// A Service because it touches UIKit: `Features/` may not, so the setup
/// screen's view model takes this as an injected closure rather than importing
/// it (docs/03 boundary rule, docs/12 §12.3).
///
/// The only recovery the app can offer for a denied Motion & Fitness
/// permission — it cannot re-prompt once the user has said no, so it can only
/// take them to where they can change their mind [PRD §6].
enum SystemSettingsLink {
    @MainActor
    static func open() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url)
        else { return }
        UIApplication.shared.open(url)
    }
}
