// SingleTouchGestures.swift
// Пункт 1: жесты одним пальцем через стандартные NSGestureRecognizer.
// Тачскрин на macOS приходит как мышь, поэтому этого достаточно для
// double tap / pan / swipe. Tap и long press у вас уже реализованы.
//
// Использование:
//   let gestures = SingleTouchGestures(view: myView)
//   gestures.delegate = self

import AppKit

enum SwipeDirection { case left, right, up, down }

protocol SingleTouchGesturesDelegate: AnyObject {
    func singleTouchDidDoubleTap(at point: NSPoint)
    func singleTouchDidPan(translation: NSPoint, state: NSGestureRecognizer.State)
    func singleTouchDidSwipe(_ direction: SwipeDirection)
}

final class SingleTouchGestures: NSObject, NSGestureRecognizerDelegate {
    weak var delegate: SingleTouchGesturesDelegate?

    /// Минимальная скорость (pt/s) в момент отпускания, чтобы pan считался swipe.
    var swipeVelocityThreshold: CGFloat = 1000

    /// Выставляется снаружи, пока идёт мультитач-жест (пункт 3),
    /// чтобы одиночный pan не конфликтовал с pinch/rotate.
    var isSuspended = false

    private weak var view: NSView?
    private let doubleTap = NSClickGestureRecognizer()
    private let pan = NSPanGestureRecognizer()

    init(view: NSView) {
        self.view = view
        super.init()

        doubleTap.numberOfClicksRequired = 2
        doubleTap.target = self
        doubleTap.action = #selector(handleDoubleTap(_:))

        pan.target = self
        pan.action = #selector(handlePan(_:))

        ([doubleTap, pan] as [NSGestureRecognizer]).forEach {
            $0.delegate = self
            view.addGestureRecognizer($0)
        }
    }

    deinit {
        ([doubleTap, pan] as [NSGestureRecognizer]).forEach { view?.removeGestureRecognizer($0) }
    }

    // MARK: - Handlers

    @objc private func handleDoubleTap(_ g: NSClickGestureRecognizer) {
        guard let view, !isSuspended else { return }
        delegate?.singleTouchDidDoubleTap(at: g.location(in: view))
    }

    @objc private func handlePan(_ g: NSPanGestureRecognizer) {
        guard let view, !isSuspended else { return }
        delegate?.singleTouchDidPan(translation: g.translation(in: view), state: g.state)

        guard g.state == .ended, let dir = swipeDirection(g.velocity(in: view), flipped: view.isFlipped)
        else { return }
        delegate?.singleTouchDidSwipe(dir)
    }

    private func swipeDirection(_ v: NSPoint, flipped: Bool) -> SwipeDirection? {
        let t = swipeVelocityThreshold
        if abs(v.x) >= abs(v.y) {
            guard abs(v.x) > t else { return nil }
            return v.x > 0 ? .right : .left
        } else {
            guard abs(v.y) > t else { return nil }
            let goingUp = flipped ? v.y < 0 : v.y > 0   // в AppKit по умолчанию y растёт вверх
            return goingUp ? .up : .down
        }
    }

    // MARK: - NSGestureRecognizerDelegate

    // Не мешаем существующей обработке mouseDown / контекстного меню.
    func gestureRecognizer(_ g: NSGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool { true }
}
