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

    // Backend URL: dev-стек по умолчанию.
    // Если запускаешь на реальном устройстве (не Simulator) — заменить
    // 127.0.0.1 на LAN-IP машины, где крутится docker.
    // Пример: URL(string: "http://192.168.1.42:4000")!
    @StateObject private var client = CobrowseClient(
        backendURL: URL(string: "http://192.168.10.10:4000")!
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
        }
    }
}
