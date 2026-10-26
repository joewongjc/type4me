import SwiftUI
import os

/// Cloud-only diagnostics embedded by the universal Debug settings page.
/// This file is excluded from packages that do not include CloudSubscription.
struct CloudDebugDiagnosticsSection: View, SettingsCardHelpers {

    @State private var cnMs: String = "—"
    @State private var usMs: String = "—"
    @State private var pinging = false
    @State private var currentRegion = CloudConfig.currentRegion

    private let logger = Logger(subsystem: "com.type4me.app", category: "DebugTab")

    var body: some View {
        regionCard
        Spacer().frame(height: 16)
        endpointsCard
    }

    // MARK: - Region Card

    private var regionCard: some View {
        settingsGroupCard(L("区域", "Region"), icon: "network") {
            HStack {
                Text(L("当前区域", "Active Region"))
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextSecondary)
                Spacer()
                Text(currentRegion.rawValue.uppercased())
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(TF.settingsAccentGreen)
            }

            SettingsDivider()

            HStack(spacing: 20) {
                latencyColumn("CN (Beijing)", ms: cnMs, active: currentRegion == .cn)
                latencyColumn("US (Los Angeles)", ms: usMs, active: currentRegion == .overseas)
                Spacer()
                secondaryButton(pinging ? L("检测中...", "Pinging...") : L("检测两边", "Ping Both")) {
                    pingBoth()
                }
                .disabled(pinging)
            }

            SettingsDivider()

            HStack(spacing: 8) {
                regionButton(L("强制中国区", "Force CN"), region: .cn)
                regionButton(L("强制美国区", "Force US"), region: .overseas)
                secondaryButton(L("自动检测", "Auto Detect")) {
                    UserDefaults.standard.removeObject(forKey: "tf_cloud_region_override")
                    Task {
                        let r = await RegionDetector.detect()
                        currentRegion = r
                        pingBoth()
                    }
                }
            }

            if UserDefaults.standard.string(forKey: "tf_cloud_region_override") != nil {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(L("已启用手动指定区域，自动检测已关闭。", "Manual override active. Auto-detect disabled."))
                        .font(.system(size: 11))
                }
                .foregroundStyle(TF.settingsAccentAmber)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Endpoints Card

    private var endpointsCard: some View {
        settingsGroupCard(L("端点", "Endpoints"), icon: "server.rack") {
            endpointRow("CN API", value: CloudConfig.cnAPIEndpoint)
            SettingsDivider()
            endpointRow("US API", value: CloudConfig.usAPIEndpoint)
            SettingsDivider()
            endpointRow(L("当前", "Active"), value: CloudConfig.apiEndpoint)
        }
    }

    // MARK: - Helpers

    private func latencyColumn(_ label: String, ms: String, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TF.settingsTextSecondary)
            Text(ms)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(active ? TF.settingsAccentGreen : TF.settingsText)
        }
    }

    private func regionButton(_ label: String, region: CloudRegion) -> some View {
        let isActive = currentRegion == region
        return Button(label) {
            UserDefaults.standard.set(region.rawValue, forKey: "tf_cloud_region_override")
            CloudConfig.currentRegion = region
            currentRegion = region
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: isActive ? .bold : .medium))
        .foregroundStyle(isActive ? TF.settingsAccentGreen : TF.settingsTextSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? TF.settingsAccentGreen.opacity(0.15) : TF.settingsCardAlt)
        )
    }

    private func endpointRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TF.settingsTextSecondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(TF.settingsText)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func pingBoth() {
        pinging = true
        cnMs = "..."
        usMs = "..."
        Task {
            async let cn = ping(CloudConfig.cnAPIEndpoint + "/health")
            async let us = ping(CloudConfig.usAPIEndpoint + "/health")
            let cnResult = await cn
            let usResult = await us
            cnMs = cnResult.map { String(format: "%.0fms", $0) } ?? "timeout"
            usMs = usResult.map { String(format: "%.0fms", $0) } ?? "timeout"
            pinging = false
            logger.info("Ping results: CN=\(cnMs), US=\(usMs)")
        }
    }

    private func ping(_ urlString: String) async -> Double? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return (CFAbsoluteTimeGetCurrent() - start) * 1000
        } catch {
            return nil
        }
    }
}
