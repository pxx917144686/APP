import SwiftUI
import WidgetKit

@main
struct APPWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuickLaunchWidget()
        StorageWidget()
    }
}
