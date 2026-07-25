//
//  PrivacyView.swift
//  ringmvp
//
//  Plain-language statement that this app is entirely local.
//

import SwiftUI

struct PrivacyView: View {
    var body: some View {
        List {
            Section {
                Label("Local-only. Nothing leaves your phone.", systemImage: "lock.fill")
                    .font(.subheadline.weight(.medium))
            }

            Section("What we store") {
                Text("Heart rate, blood oxygen, blood pressure, activity, and sleep readings from your ring are saved in this app's private storage on your device.")
                    .font(.footnote)
            }

            Section("What we don't do") {
                bullet("No accounts, no sign-in.")
                bullet("No network requests — the app has no server and sends nothing to the cloud.")
                bullet("No analytics or tracking.")
                bullet("No sharing with third parties.")
            }

            Section("Bluetooth") {
                Text("Bluetooth is used only to connect to your ring and read its measurements. The connection is direct between your phone and the ring.")
                    .font(.footnote)
            }

            Section("Your control") {
                Text("You can delete all stored readings at any time from the History tab, and unpair the ring with Forget on the Ring tab.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bullet(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle")
            .font(.footnote)
            .labelStyle(.titleAndIcon)
    }
}
