import AVKit
import SwiftUI

/// 系统 AirPlay 设备选择按钮
#if os(macOS)
struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context _: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        picker.setRoutePickerButtonColor(.white, for: .normal)
        picker.setRoutePickerButtonColor(.controlAccentColor, for: .active)
        return picker
    }

    func updateNSView(_: AVRoutePickerView, context _: Context) {}
}
#else
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context _: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .tintColor
        picker.prioritizesVideoDevices = true
        return picker
    }

    func updateUIView(_: AVRoutePickerView, context _: Context) {}
}
#endif
