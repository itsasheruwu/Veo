// FILE: DesktopReviewSheet.swift
// Purpose: Native review-target and delivery picker for app-server reviews.
// Layer: Desktop app view

import SwiftUI

struct DesktopReviewSheet: View {
    @ObservedObject var store: DesktopCodexStore
    @Environment(\.dismiss) private var dismiss
    @State private var request = DesktopReviewRequest()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Review changes")
                    .font(.system(size: 20, weight: .semibold))
                Text("Choose what Codex should review and where the result should appear.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            Form {
                Picker("Target", selection: $request.target) {
                    ForEach(DesktopReviewTargetKind.allCases) { target in
                        Text(target.title).tag(target)
                    }
                }

                if request.target != .uncommittedChanges {
                    if request.target == .custom {
                        TextEditor(text: $request.value)
                            .font(.system(size: 12.5))
                            .frame(minHeight: 82)
                            .overlay(alignment: .topLeading) {
                                if request.value.isEmpty {
                                    Text(request.target.prompt)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 7)
                                        .allowsHitTesting(false)
                                }
                            }
                    } else {
                        TextField(request.target.prompt, text: $request.value)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Picker("Result", selection: $request.delivery) {
                    ForEach(DesktopReviewDelivery.allCases) { delivery in
                        Text(delivery.title).tag(delivery)
                    }
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Review") {
                    store.reviewChanges(request)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!request.isValid || store.isBusyTurn)
            }
        }
        .padding(22)
        .frame(width: 470)
    }
}
