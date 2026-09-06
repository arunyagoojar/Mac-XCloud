//
//  ProfileLaunchRows.swift
//  Mac XCloud
//
//  Native entry points for Better xCloud profile managers and the bundled
//  forced-native-MKB game list.
//

import SwiftUI

struct ProfileLaunchButton: View {
    @EnvironmentObject private var browser: BrowserModel
    let kind: ProfileKind
    let title: String
    let note: String

    var body: some View {
        Button {
            browser.openProfileEditor(kind)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

