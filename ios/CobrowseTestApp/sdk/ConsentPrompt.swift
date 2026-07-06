//
//  ConsentPrompt.swift
//  CobrowsePOC
//
//  Явный consent перед стартом записи экрана.
//  Требование Apple HIG + базовая этика + закон (152-ФЗ, GDPR).
//

import UIKit

public enum ConsentPrompt {

    /// Показать модальный alert с описанием того, что увидит оператор.
    /// Возвращает true, если пользователь нажал "Разрешить", иначе false.
    @MainActor
    public static func requestConsent() async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(
                title: "Поделиться экраном с оператором",
                message: """
                Оператор поддержки увидит то, что отображается на экране этого приложения.

                Оператор НЕ увидит:
                • Уведомления и другие приложения
                • Поля с банковскими картами и паролями
                • Содержимое экрана за пределами этого приложения

                Вы можете прекратить сессию в любой момент.
                """,
                preferredStyle: .alert
            )

            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in
                continuation.resume(returning: false)
            })
            alert.addAction(UIAlertAction(title: "Разрешить", style: .default) { _ in
                continuation.resume(returning: true)
            })

            // Показываем в topmost view controller.
            // В production-SDK лучше принимать presenting VC параметром.
            guard let topVC = Self.topMostViewController() else {
                continuation.resume(returning: false)
                return
            }
            topVC.present(alert, animated: true)
        }
    }

    @MainActor
    private static func topMostViewController() -> UIViewController? {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: \.isKeyWindow),
              var top = window.rootViewController else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
