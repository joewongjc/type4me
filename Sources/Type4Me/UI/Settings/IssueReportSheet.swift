import AppKit
import SwiftUI

struct IssueReportSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var problemDescription = ""
    @State private var includeLogs = true
    @State private var reportStatus: ReportStatus?
    @State private var isGitHubConnected = false
    @State private var isSubmitting = false
    @State private var githubAuthorization: GitHubDeviceAuthorization?
    @State private var authorizationTask: Task<Void, Never>?

    private let environment = IssueReportEnvironment.current
    private let githubReporter = GitHubIssueReporter.shared

    private var canCreateReport: Bool {
        !problemDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("报告问题", "Report an Issue"))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(TF.settingsText)
                    Text(L(
                        "填写问题后可直接创建 GitHub Issue；首次提交需要授权 GitHub。",
                        "Describe the problem and create a GitHub issue directly. GitHub authorization is required the first time."
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextSecondary)
                }

                Spacer()

                TFCloseButton { dismiss() }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(L("问题描述（必填）", "Problem description (required)"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsText)
                TextEditor(text: $problemDescription)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .background(TF.settingsCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(TF.settingsTextTertiary.opacity(0.25), lineWidth: 1)
                    )
                    .frame(minHeight: 160)
                Text(L(
                    "建议写清楚：发生了什么、如何复现、你原本期待什么。",
                    "Include what happened, how to reproduce it, and what you expected."
                ))
                .font(.system(size: 10))
                .foregroundStyle(TF.settingsTextTertiary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Toggle(isOn: $includeLogs) {
                    Text(L("包含最近的诊断日志", "Include recent diagnostic logs"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TF.settingsText)
                }
                .toggleStyle(.checkbox)

                Text(L(
                    "日志会自动隐藏 API Key、Token、邮箱、用户目录和输入框文本，但仍建议在 GitHub 提交前快速检查。",
                    "API keys, tokens, email addresses, home paths, and detected input text are redacted automatically. Please still review before submitting."
                ))
                .font(.system(size: 10))
                .foregroundStyle(TF.settingsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let reportStatus {
                Label(
                    reportStatus.message,
                    systemImage: reportStatus.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                )
                    .font(.system(size: 11))
                    .foregroundStyle(reportStatus.isError ? .orange : .green)
            }

            if let authorization = githubAuthorization {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("GitHub 设备授权码", "GitHub device code"))
                            .font(.system(size: 10))
                            .foregroundStyle(TF.settingsTextTertiary)
                        Text(authorization.userCode)
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(TF.settingsText)
                    }
                    Spacer()
                    Button(L("复制并打开授权页", "Copy & Open Authorization")) {
                        openAuthorizationPage(authorization)
                    }
                    .buttonStyle(.tf(.secondary, size: .small))
                }
                .padding(10)
                .background(TF.settingsCardAlt)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 10) {
                Button(L("取消", "Cancel")) {
                    dismiss()
                }
                .buttonStyle(.tf(.secondary))

                Spacer()

                Button {
                    copyFullReport()
                } label: {
                    Label(L("复制完整报告", "Copy Full Report"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.tf(.secondary))
                .disabled(!canCreateReport)

                Button {
                    openGitHubIssueInBrowser()
                } label: {
                    Label(L("浏览器提交", "Submit in Browser"), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.tf(.secondary))
                .disabled(!canCreateReport || isSubmitting)

                Button {
                    submitIssue()
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(
                            isGitHubConnected
                                ? L("直接提交", "Submit Directly")
                                : L("连接 GitHub 并提交", "Connect GitHub & Submit"),
                            systemImage: "paperplane.fill"
                        )
                    }
                }
                .buttonStyle(.tf(.primary))
                .disabled(!canCreateReport || isSubmitting)
            }
        }
        .padding(24)
        .frame(width: 640, height: githubAuthorization == nil ? 475 : 550)
        .background(TF.settingsBg)
        .task {
            isGitHubConnected = await githubReporter.isConnected()
        }
        .onDisappear {
            authorizationTask?.cancel()
        }
    }

    private func reportInputs() -> (title: String, log: String, report: String) {
        let log = includeLogs
            ? DebugFileLogger.reportContents(maxCharacters: IssueReportService.maximumReportLogCharacters)
            : ""
        let title = IssueReportService.suggestedTitle(
            customTitle: "",
            description: problemDescription
        )
        let report = IssueReportService.fullReport(
            description: problemDescription,
            environment: environment,
            includeLogs: includeLogs,
            logText: log
        )
        return (title, log, report)
    }

    private func copyFullReport() {
        let inputs = reportInputs()
        copyToPasteboard(inputs.report)
        reportStatus = ReportStatus(
            message: L("完整报告已复制", "Full report copied"),
            isError: false
        )
        DebugFileLogger.log("issue reporter: full report copied")
    }

    private func openGitHubIssueInBrowser() {
        let inputs = reportInputs()
        copyToPasteboard(inputs.report)

        guard let url = IssueReportService.githubIssueURL(
            title: inputs.title,
            description: problemDescription,
            environment: environment,
            includeLogs: includeLogs,
            logText: inputs.log
        ) else {
            reportStatus = ReportStatus(
                message: L("无法生成链接，完整报告已复制", "Could not create the link; full report copied"),
                isError: true
            )
            return
        }

        if NSWorkspace.shared.open(url) {
            reportStatus = ReportStatus(
                message: L("已打开 GitHub，完整报告也已复制", "GitHub opened; the full report is also copied"),
                isError: false
            )
            DebugFileLogger.log("issue reporter: GitHub new issue opened")
        } else {
            reportStatus = ReportStatus(
                message: L("无法打开浏览器，完整报告已复制", "Could not open the browser; full report copied"),
                isError: true
            )
        }
    }

    private func submitIssue() {
        guard canCreateReport, authorizationTask == nil else { return }
        isSubmitting = true
        reportStatus = ReportStatus(
            message: isGitHubConnected
                ? L("正在创建 GitHub Issue…", "Creating GitHub issue…")
                : L("正在连接 GitHub…", "Connecting GitHub…"),
            isError: false
        )

        authorizationTask = Task { @MainActor in
            defer {
                isSubmitting = false
                authorizationTask = nil
            }

            do {
                if !isGitHubConnected {
                    let authorization = try await githubReporter.beginAuthorization()
                    githubAuthorization = authorization
                    copyToPasteboard(authorization.userCode)
                    NSWorkspace.shared.open(authorization.verificationURL)
                    reportStatus = ReportStatus(
                        message: L(
                            "请在 GitHub 输入授权码，授权完成后会自动提交。",
                            "Enter the code on GitHub; the report will submit automatically after authorization."
                        ),
                        isError: false
                    )
                    try await githubReporter.finishAuthorization(authorization)
                    isGitHubConnected = true
                    githubAuthorization = nil
                    DebugFileLogger.log("issue reporter: GitHub connected")
                }

                let inputs = reportInputs()
                let issue = try await githubReporter.createIssue(
                    title: inputs.title,
                    body: inputs.report
                )
                reportStatus = ReportStatus(
                    message: L("Issue #\(issue.number) 已创建", "Issue #\(issue.number) created"),
                    isError: false
                )
                DebugFileLogger.log("issue reporter: issue created number=\(issue.number)")
                NSWorkspace.shared.open(issue.url)
            } catch is CancellationError {
                githubAuthorization = nil
                reportStatus = ReportStatus(
                    message: L("GitHub 提交已取消", "GitHub submission cancelled"),
                    isError: true
                )
            } catch {
                githubAuthorization = nil
                if case GitHubReporterError.authorizationRevoked = error {
                    isGitHubConnected = false
                } else if case GitHubReporterError.insufficientScope = error {
                    isGitHubConnected = false
                }
                reportStatus = ReportStatus(
                    message: L("提交失败：\(error.localizedDescription)", "Submission failed: \(error.localizedDescription)"),
                    isError: true
                )
                let nsError = error as NSError
                DebugFileLogger.log(
                    "issue reporter: submit failed domain=\(nsError.domain) code=\(nsError.code) message=\(error.localizedDescription)"
                )
            }
        }
    }

    private func openAuthorizationPage(_ authorization: GitHubDeviceAuthorization) {
        copyToPasteboard(authorization.userCode)
        NSWorkspace.shared.open(authorization.verificationURL)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct ReportStatus {
    let message: String
    let isError: Bool
}
