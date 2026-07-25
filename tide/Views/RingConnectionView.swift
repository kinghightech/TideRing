//
//  RingConnectionView.swift
//  Tide
//
//  All ring connectivity in one place: scan, connect, device status, and the ring-level actions
//  (sync, find, disconnect, forget). Reached from the home status pill and from Settings.
//
//  Adapts to the system appearance: deep ocean in dark mode, a calm light-blue wash over white in
//  light mode — matching the rest of the app.
//

import SwiftUI

struct RingConnectionView: View {
    @ObservedObject var manager: RingManager

    private var isConnected: Bool { manager.connectionState == .connected }

    var body: some View {
        ZStack {
            TideBackground()
            ScrollView {
                VStack(spacing: 20) {
                    statusCard
                    if isConnected {
                        TideSettingsSection(header: "Ring") {
                            ringNameRow
                            actionRow(
                                manager.syncProgress == nil ? "Sync history" : "Syncing history…",
                                "arrow.triangle.2.circlepath",
                                tint: TideColors.accent,
                                disabled: manager.syncProgress != nil
                            ) { manager.syncHistory() }
                            actionRow("Sync clock", "clock.arrow.circlepath", tint: Color(red: 0.42, green: 0.55, blue: 0.95)) { manager.syncClock() }
                            actionRow("Find ring", "wave.3.right", tint: Color(red: 0.30, green: 0.74, blue: 0.68)) { manager.findDevice() }
                        }
                        TideSettingsSection {
                            actionRow("Disconnect", "xmark.circle", tint: .orange) { manager.disconnect() }
                            actionRow("Forget ring", "trash", tint: .red, destructive: true) { manager.forget() }
                        }
                    } else {
                        scanCard
                    }
                }
                .padding()
            }
        }
        .navigationTitle(manager.settings.displayRingName)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                Text(manager.connectionState.displayName).font(.headline).foregroundStyle(.primary)
                Spacer()
                if let b = manager.batteryPercent {
                    Label("\(b)%", systemImage: batteryIcon(b))
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            Text("Bluetooth \(manager.bluetoothStateText) · \(manager.authorizationText)")
                .font(.caption).foregroundStyle(.secondary)
            if manager.isBound {
                Label("Bound to ring", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
            }
            if let error = manager.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let progress = manager.syncProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.caption).foregroundStyle(.secondary)
                }
            } else if let message = manager.syncResultMessage {
                Label(message, systemImage: message.hasPrefix("Synced") || message.contains("up to date")
                      ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(message.hasPrefix("Synced") || message.contains("up to date") ? .green : .orange)
            } else if let lastSyncAt = manager.lastSyncAt {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Last history sync")
                    Text(lastSyncAt, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
    }

    // MARK: Actions (settings-page row style)

    private var ringName: Binding<String> {
        Binding(
            get: { manager.settings.ringName ?? "" },
            set: {
                let trimmed = String($0.prefix(40))
                manager.settings.ringName = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    private var ringNameRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "pencil")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(TideColors.accent.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text("Ring name").font(.body).foregroundStyle(.primary)
            Spacer(minLength: 8)
            TextField("Tide Ring", text: ringName)
                .textInputAutocapitalization(.words)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 170)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 52)
    }

    private func actionRow(_ title: String, _ icon: String, tint: Color,
                           destructive: Bool = false, disabled: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title).font(.body).foregroundStyle(destructive ? Color.red : .primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.65 : 1)
    }

    // MARK: Scan (disconnected)

    private var scanCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Nearby Devices").font(.headline).foregroundStyle(.primary)
                Spacer()
                if manager.connectionState == .scanning {
                    Button("Stop") { manager.stopScanning() }.font(.subheadline)
                } else {
                    Button("Scan") { manager.startScanning() }
                        .font(.subheadline.weight(.semibold))
                        .disabled(!manager.isBluetoothReady)
                }
            }
            .tint(TideColors.accent)

            if manager.discovered.isEmpty {
                Text(manager.connectionState == .scanning ? "Scanning…" : "Tap Scan to find your ring.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ForEach(manager.discovered) { device in
                    Button { manager.connect(to: device.id) } label: {
                        HStack {
                            Image(systemName: device.isLikelyRing ? "circle.hexagongrid.circle.fill" : "dot.radiowaves.left.and.right")
                                .foregroundStyle(device.isLikelyRing ? TideColors.accent : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                Text("\(device.isLikelyRing ? "Smart ring · " : "")RSSI \(device.rssi)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    if device.id != manager.discovered.last?.id { Divider() }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
    }

    private var statusColor: Color {
        switch manager.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting, .scanning: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }

    private func batteryIcon(_ percent: Int) -> String {
        switch percent {
        case 0..<15: return "battery.25"
        case 15..<55: return "battery.50"
        case 55..<85: return "battery.75"
        default: return "battery.100"
        }
    }
}

/// Compact key/value row reused on the diagnostics screen.
struct DetailRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).textSelection(.enabled)
        }
        .font(.subheadline)
    }
}
