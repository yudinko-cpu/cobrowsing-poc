//
//  SessionTab.swift
//  CobrowseTestApp
//
//  Обёртка над SessionEntryView из SDK — тут стартуется и останавливается сессия.
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
        .environmentObject(CobrowseClient(backendURL: URL(string: "http://192.168.10.1:4000")!))
}
