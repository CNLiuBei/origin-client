import AVKit
import SwiftUI
import UIKit

/// 用 UIKit 原生手势识别器处理播放器手势：单击、双击、平移、长按、捏合
struct PlayerGestureView: UIViewRepresentable {
    enum Axis {
        case horizontal
        case vertical
    }

    enum PanPhase {
        case began(Axis, xFraction: CGFloat)
        case changed(Axis, xFraction: CGFloat, translation: CGPoint, size: CGSize)
        case ended(Axis)
    }

    var volumeController: SystemVolumeController
    var onTap: () -> Void
    var onDoubleTap: (CGFloat) -> Void
    var onPan: (PanPhase) -> Void
    var onLongPress: (Bool) -> Void
    var onPinch: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIView {
        let view = GestureHostView()
        view.backgroundColor = .clear
        view.volumeController = volumeController
        view.addSubview(volumeController.volumeView)
        volumeController.volumeView.alpha = 0.01

        let c = context.coordinator
        let doubleTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: doubleTap)
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        let longPress = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.longPress(_:)))
        longPress.minimumPressDuration = 0.45
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        for recognizer in [doubleTap, tap, pan, longPress, pinch] {
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class GestureHostView: UIView {
        var volumeController: SystemVolumeController?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            volumeController?.screen = window?.windowScene?.screen
        }
    }

    final class Coordinator: NSObject {
        var parent: PlayerGestureView
        private var axis: Axis = .horizontal
        private var startX: CGFloat = 0

        init(parent: PlayerGestureView) {
            self.parent = parent
        }

        @objc func tap(_: UITapGestureRecognizer) {
            parent.onTap()
        }

        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            parent.onDoubleTap(recognizer.location(in: view).x / max(view.bounds.width, 1))
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let size = view.bounds.size
            switch recognizer.state {
            case .began:
                let velocity = recognizer.velocity(in: view)
                axis = abs(velocity.x) >= abs(velocity.y) ? .horizontal : .vertical
                startX = recognizer.location(in: view).x / max(size.width, 1)
                parent.onPan(.began(axis, xFraction: startX))
            case .changed:
                parent.onPan(.changed(axis, xFraction: startX, translation: recognizer.translation(in: view), size: size))
            case .ended, .cancelled, .failed:
                parent.onPan(.ended(axis))
            default:
                break
            }
        }

        @objc func longPress(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began: parent.onLongPress(true)
            case .ended, .cancelled, .failed: parent.onLongPress(false)
            default: break
            }
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            if recognizer.state == .ended {
                parent.onPinch(recognizer.scale)
            }
        }
    }
}
