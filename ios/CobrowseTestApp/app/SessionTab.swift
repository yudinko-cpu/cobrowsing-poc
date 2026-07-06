//
//  SessionTab.swift
//  CobrowseTestApp
//
//  Обёртка над SessionEntryView из SDK — тут стартуется и останавливается сессия.
//  Настройки видео вынесены в глобальный overlay в ContentView, чтобы шестерёнка
//  была доступна с любого таба.
//

import SwiftUI

struct SessionTab: View {
    @EnvironmentObject var client: CobrowseClient

    var body: some View {
        NavigationView {
            SessionEntryView(client: client)
                .navigationTitle("Cobrowse Test")
        }
        .navigationViewStyle(.stack)
    }
}

#Preview {
    SessionTab()
        .environmentObject(CobrowseClient(backendURL: AppConfig.backendURL))
}
