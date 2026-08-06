//
//  TideCoachView.swift
//  Tide
//
//  Chat surface for `TideCoach`. Runs entirely on-device via Apple's Foundation Models framework.
//

import FoundationModels
import SwiftUI
import UIKit

struct TideCoachView: View {
    @ObservedObject var manager: RingManager
    @ObservedObject var store: RingStore
    @StateObject private var coach = TideCoach()

    @State private var draft = ""
    @State private var showingHistory = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let reason = coach.unavailableReason {
                    unavailable(reason)
                } else {
                    conversation
                }
            }
            .background(TideBackground())
            .navigationTitle("Coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if coach.unavailableReason == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingHistory = true
                        } label: {
                            Label("Saved chats", systemImage: "clock.arrow.circlepath")
                        }
                        .disabled(coach.savedConversations.isEmpty)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            coach.startNewConversation()
                        } label: {
                            Label("New chat", systemImage: "square.and.pencil")
                        }
                        .disabled(coach.isResponding || (coach.activeConversation?.isEmpty ?? true))
                    }
                }
            }
            .sheet(isPresented: $showingHistory) {
                TideCoachHistoryView(coach: coach)
            }
        }
    }

    // MARK: Conversation

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if coach.messages.isEmpty { emptyState }

                        ForEach(coach.messages) { message in
                            bubble(message).id(message.id)
                        }

                        if let error = coach.errorMessage {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Anchor so the newest text stays in view while a reply streams in.
                        Color.clear.frame(height: 1).id(scrollAnchor)
                    }
                    .padding()
                }
                .onChange(of: coach.messages.last?.text) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(scrollAnchor, anchor: .bottom) }
                }
                .onChange(of: coach.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(scrollAnchor, anchor: .bottom) }
                }
            }

            composer
        }
    }

    private let scrollAnchor = "tide.coach.bottom"

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(TideColors.accent)
                Text("Ask about your health")
                    .font(TideFont.serif(28, weight: .regular))
                Text("Tide Coach reads the data your ring has collected and answers in plain language. It runs entirely on your iPhone — nothing is sent anywhere.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            VStack(spacing: 8) {
                ForEach(TideCoach.starters, id: \.self) { starter in
                    Button {
                        submit(starter)
                    } label: {
                        HStack {
                            Text(starter).font(.subheadline)
                            Spacer()
                            Image(systemName: "arrow.up.circle.fill").foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Tide Coach gives general wellness suggestions. It is not a doctor and cannot diagnose anything.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func bubble(_ message: TideCoachMessage) -> some View {
        switch message.role {
        case .user:
            Text(message.text)
                .font(.subheadline)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(TideColors.accent.opacity(0.22), in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: .infinity, alignment: .trailing)

        case .assistant:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.footnote)
                    .foregroundStyle(TideColors.accent)
                    .padding(.top, 3)

                if message.text.isEmpty, message.isStreaming {
                    ProgressView().controlSize(.small)
                } else {
                    Text(message.text)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Ask about your health…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .submitLabel(.send)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(.ultraThinMaterial, in: Capsule())

            Button {
                submit(draft)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? TideColors.accent : .secondary)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !coach.isResponding
    }

    private func submit(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !coach.isResponding else { return }
        draft = ""
        inputFocused = false
        Task { await coach.send(question, store: store, settings: manager.settings) }
    }

    // MARK: Unavailable

    private func unavailable(_ reason: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Coach unavailable").font(.headline)
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if case .unavailable(.appleIntelligenceNotEnabled) = coach.availability,
               let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url)
                    .font(.subheadline.weight(.medium))
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Saved chats

private struct TideCoachHistoryView: View {
    @ObservedObject var coach: TideCoach
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(coach.savedConversations) { conversation in
                    Button {
                        coach.select(conversation.id)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(conversation.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                Text("·")
                                Text("\(conversation.messages.count) messages")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .listRowBackground(
                        conversation.id == coach.activeID
                            ? TideColors.accent.opacity(0.12)
                            : Color.clear
                    )
                }
                .onDelete { offsets in
                    for index in offsets {
                        coach.delete(coach.savedConversations[index].id)
                    }
                }
            }
            .navigationTitle("Saved chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Delete all chats", systemImage: "trash", role: .destructive) {
                            coach.deleteAll()
                            dismiss()
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .overlay {
                if coach.savedConversations.isEmpty {
                    ContentUnavailableView(
                        "No saved chats",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Chats you have with Tide Coach are saved here automatically.")
                    )
                }
            }
        }
    }
}
