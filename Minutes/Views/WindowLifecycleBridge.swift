import SwiftUI
import AppKit

/// 将 SwiftUI 主窗口接入 AppDelegate 的关闭确认，不触碰窗口内容布局。
struct WindowLifecycleBridge: NSViewRepresentable {
    let appDelegate: AppDelegate

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            appDelegate.mainWindow = window
            window.delegate = appDelegate
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
