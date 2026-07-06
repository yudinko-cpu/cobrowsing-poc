//
//  SessionTab.swift
//  CobrowseTestApp
//
//  Обёртка над SessionEntryView из SDK — тут стартуется и останавливается сессия.
//  Плюс — доступ к live-настройкам видео через кнопку-шестерёнку в NavigationBar,
//  видна только при активной сессии (.streaming/.reconnecting).
//

import SwiftUI

struct SessionTab: View {
    @EnvironmentObject var client: CobrowseClient
    @State private var showVideoSettings = false

    var body: some View {
        NavigationView {
            SessionEntryView(client: client)
                .navigationTitle("Cobrowse Test")
                .toolbar {
                    if isSessionActive {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                showVideoSettings = true
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                            }
                            .accessibilityLabel("Настройки видео")
                        }
                    }
                }
                .sheet(isPresented: $showVideoSettings) {
                    VideoSettingsSheet(current: client.screenShareOptions)
                        .environmentObject(client)
                }
        }
        .navigationViewStyle(.stack)
    }

    /// Показываем шестерёнку только когда есть живой видео-трек, который
    /// имеет смысл перенастраивать. В .reconnecting не показываем —
    /// republishScreenShare там кинет .notStreaming.
    private var isSessionActive: Bool {
        if case .streaming = client.state { return true }
        return false
    }
}

#Preview {
    SessionTab()
        .environmentObject(CobrowseClient(backendURL: AppConfig.backendURL))
}
