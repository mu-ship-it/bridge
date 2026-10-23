import SwiftUI
import WidgetKit

/// The macOS desktop widgets: only the board, with the same views as iOS (Shared/BoardViews.swift).
@main
struct BridgeMacWidgetBundle: WidgetBundle {
    var body: some Widget {
        BridgeBoardWidget()
    }
}
