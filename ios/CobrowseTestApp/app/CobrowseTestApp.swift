//
//  CobrowseTestApp.swift
//  CobrowseTestApp
//
//  Тестовое iOS-приложение для отладки cobrowsing screen share.
//  Инициализирует CobrowseClient и оборачивает всё в TabView с полезными
//  для проверки шаринга сценариями.
//

import SwiftUI

@main
struct CobrowseTestApp: App {

    // Backend URL — в AppConfig. Дефолт (127.0.0.1) работает для Simulator
    // и браузера на этом же Mac. Для реального iPhone — override через
    // Scheme → Run → Arguments: `-CobrowseBackendURL http://<LAN-IP>:4000`.
    @StateObject private var client = CobrowseClient(backendURL: AppConfig.backendURL)

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
        }
    }
}
