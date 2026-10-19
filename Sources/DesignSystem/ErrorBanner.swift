import ContainerKit
import SwiftUI

/// Inline error with the cleaned CLI message, the exact failing command (copyable), and an optional retry.
public struct ErrorBanner: View {
    let error: BackendError
    let retry: (() -> Void)?
    let dismiss: (() -> Void)?

    public init(_ error: BackendError, retry: (() -> Void)? = nil, dismiss: (() -> Void)? = nil) {
        self.error = error
        self.retry = retry
        self.dismiss = dismiss
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.statusError)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(error.title).font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(error.errorDescription ?? "Unknown error")
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(6)
                if let command = error.maskedFailedCommand {
                    HStack(spacing: Spacing.xs) {
                        Text(command)
                            .font(.monoCaption)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .padding(.horizontal, Spacing.s)
                            .padding(.vertical, Spacing.xxs)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: Radius.small))
                        CopyButton(command, label: "Copy command")
                    }
                }
            }
            Spacer(minLength: 0)
            if let retry {
                Button("Retry", action: retry)
                    .help("Try again")
            }
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss error")
            }
        }
        .padding(Spacing.m)
        .background(Color.statusError.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(Color.statusError.opacity(0.25)))
        .accessibilityElement(children: .contain)
    }
}

#Preview("ErrorBanner") {
    VStack {
        ErrorBanner(
            .commandFailed(command: "container image pull nope:latest", exitCode: 1, message: "Error: image not found"),
            retry: {}, dismiss: {})
        ErrorBanner(.unsupported(feature: "listContainers()", reason: "CLIBackend not implemented yet"), retry: {})
    }
    .padding()
    .frame(width: 560)
}
