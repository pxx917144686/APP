import SwiftUI
import WidgetKit

@main
struct APPWidgetBundle: WidgetBundle {
    var body: some Widget {
        APPWidgetLiveActivity()
        DecryptActivityWidget()
        InstallActivityWidget()
        QuickLaunchWidget()
        StorageWidget()
    }
}
