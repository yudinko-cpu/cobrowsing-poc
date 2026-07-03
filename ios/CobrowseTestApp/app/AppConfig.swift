//
//  AppConfig.swift
//  CobrowseTestApp
//
//  Единый источник конфига iOS-приложения — по аналогии с infra/.env.dev
//  на бэкенде. Все места, которым нужен backend URL, ходят сюда.
//

import Foundation

enum AppConfig {

    /// URL token-server'а. Приоритет чтения:
    ///
    /// 1. **UserDefaults ключ `CobrowseBackendURL`** — самый удобный способ
    ///    переключаться между Simulator (`127.0.0.1`) и реальным iPhone (LAN-IP)
    ///    без правки кода и пересборки. Задаётся в Xcode:
    ///
    ///        Product → Scheme → Edit Scheme → Run → Arguments →
    ///        Arguments Passed On Launch:
    ///            -CobrowseBackendURL http://192.168.1.42:4000
    ///
    ///    (Флаг `-key value` кладётся в UserDefaults автоматически при запуске.)
    ///
    /// 2. **Хардкод-дефолт ниже** — `http://127.0.0.1:4000`. Совпадает с
    ///    `HOST_IP` + `TOKEN_SERVER_PORT` из `infra/.env.dev.example`.
    ///    Simulator и браузер на этом же Mac ходят по 127.0.0.1 через
    ///    loopback хоста — всё работает без Scheme override.
    ///
    /// Реальному iPhone нужен LAN-IP (127.0.0.1 указывает на сам телефон),
    /// поэтому для него — вариант 1.
    static let backendURL: URL = {
        if let raw = UserDefaults.standard.string(forKey: "CobrowseBackendURL"),
           let url = URL(string: raw),
           url.scheme?.hasPrefix("http") == true {
            return url
        }
        return URL(string: "http://127.0.0.1:4000")!
    }()
}
