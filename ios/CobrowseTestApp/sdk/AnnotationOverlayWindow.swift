//
//  AnnotationOverlayWindow.swift
//  CobrowsePOC
//
//  Overlay-окно операторских аннотаций на клиенте.
//
//    • AnnotationOverlayWindow — отдельный pass-through UIWindow над контентом
//      приложения. hitTest → nil: тач-события уходят в приложение, клиент
//      пользуется UI сквозь слой, а оператор «рисует» поверх.
//    • AnnotationOverlayHost — менеджер жизненного цикла окна (show/hide на
//      активной сцене). Хост-приложение зовёт его по CobrowseClient.state.
//
//  Сам рендер стора живёт в AnnotationRenderer.swift (AnnotationCanvasView).
//
//  Overlay попадает в кадр ReplayKit (in-app capture) → оператор видит свою
//  аннотацию ещё и в возвращаемом видео (round-trip ACK). Это ожидаемо (§8).
//
//  См. docs/annotations-plan.md (§8 iOS overlay).
//

import UIKit
import SwiftUI

// MARK: - Pass-through окно

/// UIWindow, полностью прозрачный для касаний. Никогда не перехватывает тач —
/// все события проходят в окна ниже (приложение клиента).
final class AnnotationOverlayWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        return nil
    }
}

// MARK: - Менеджер жизненного цикла

/// Создаёт/снимает overlay-окно на активной оконной сцене. Один инстанс на
/// приложение; идемпотентен (повторные show/hide безопасны).
@MainActor
public final class AnnotationOverlayHost {

    private var window: AnnotationOverlayWindow?

    public init() {}

    /// Показать overlay поверх приложения, привязав рендер к стору.
    public func show(store: AnnotationStore) {
        guard window == nil else { return }
        guard let scene = Self.activeWindowScene() else { return }

        let w = AnnotationOverlayWindow(windowScene: scene)
        // Над контентом приложения, под системными алертами.
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        w.backgroundColor = .clear
        w.isUserInteractionEnabled = false   // подстраховка к hitTest → nil

        let host = UIHostingController(rootView: AnnotationCanvasView(store: store))
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        w.rootViewController = host

        w.isHidden = false                   // показываем, но НЕ делаем key
        window = w
    }

    /// Снять overlay.
    public func hide() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }

    /// Активная оконная сцена (foreground). Fallback — любая доступная.
    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}
