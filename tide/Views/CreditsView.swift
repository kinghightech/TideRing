//
//  CreditsView.swift
//  ringmvp
//
//  Attribution for the ported protocol implementation.
//

import SwiftUI

struct CreditsView: View {
    var body: some View {
        List {
            Section("Ring Protocol") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PulseLoop")
                        .font(.headline)
                    Text("by Saksham Bhutani")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Tide's JRing Bluetooth pairing, binding, and sensor protocol is adapted from the PulseLoop iOS project, which is verified working on this ring hardware.")
                        .font(.footnote)
                    Link("github.com/saksham2001/PulseLoopiOS",
                         destination: URL(string: "https://github.com/saksham2001/PulseLoopiOS")!)
                        .font(.footnote)
                }
                .padding(.vertical, 4)
            }

            Section("License") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Creative Commons Attribution 4.0 International (CC BY 4.0)")
                        .font(.subheadline.weight(.medium))
                    Text("The adapted protocol code is used under the CC BY 4.0 license. You are free to share and adapt the material for any purpose, provided appropriate credit is given to the original author, Saksham Bhutani.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link("creativecommons.org/licenses/by/4.0",
                         destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                        .font(.footnote)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Credits")
        .navigationBarTitleDisplayMode(.inline)
    }
}
