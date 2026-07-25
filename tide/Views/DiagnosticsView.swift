//
//  DiagnosticsView.swift
//  Tide
//
//  The raw protocol trace — every TX/RX frame with its decode — kept out of the main UI but available
//  for verifying pairing/binding and sensor activation against a real ring.
//

import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var manager: RingManager

    var body: some View {
        VStack(spacing: 0) {
            diagnostics
            Divider()
            logFeed
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") { manager.clearLog() }
            }
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 4) {
            DetailRow(label: "State", value: manager.connectionState.displayName)
            DetailRow(label: "Bluetooth", value: manager.bluetoothStateText)
            DetailRow(label: "Bound", value: manager.isBound ? "Yes" : "No")
            if let caps = manager.bandCapabilities {
                DetailRow(label: "Capabilities", value:
                    "temp \(caps.hasTemperature ? "✓" : "✗") · spo2-sep \(caps.separateBloodOxygenMode ? "✓" : "✗") · spo2-hist \(caps.hasOxygenOfflineHistory ? "✓" : "✗") · pressure-hist \(caps.hasPressureHistory ? "✓" : "✗")")
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    private var logFeed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if manager.debugLog.isEmpty {
                        Text("Protocol activity will appear here.")
                            .foregroundStyle(.secondary).padding()
                    }
                    ForEach(manager.debugLog) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text(tag(for: line.kind))
                                .font(.system(.caption2, design: .monospaced).weight(.bold))
                                .foregroundStyle(color(for: line.kind))
                                .frame(width: 26, alignment: .leading)
                            Text(line.text)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(color(for: line.kind))
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal).padding(.vertical, 6)
            }
            .onChange(of: manager.debugLog.count) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private func tag(for kind: RingLogLine.Kind) -> String {
        switch kind {
        case .info: return "•"
        case .tx: return "TX"
        case .rx: return "RX"
        }
    }

    private func color(for kind: RingLogLine.Kind) -> Color {
        switch kind {
        case .info: return .secondary
        case .tx: return .orange
        case .rx: return .green
        }
    }
}
