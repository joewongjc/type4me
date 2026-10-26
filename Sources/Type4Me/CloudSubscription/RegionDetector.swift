import Foundation
import os

/// Detects the best region by pinging both CN and US API endpoints.
/// Respects manual override via UserDefaults key `tf_cloud_region_override`.
enum RegionDetector {

    private static let logger = Logger(subsystem: "com.type4me.app", category: "Region")

    /// Detect and persist the best region. Returns immediately if manually overridden.
    static func detect() async -> CloudRegion {
        // Manual override takes priority
        if let manual = UserDefaults.standard.string(forKey: "tf_cloud_region_override"),
           let region = CloudRegion(rawValue: manual) {
            CloudConfig.currentRegion = region
            logger.info("Region override: \(region.rawValue)")
            return region
        }

        // Ping both endpoints concurrently
        async let cnMs = ping(CloudConfig.cnAPIEndpoint + "/health")
        async let usMs = ping(CloudConfig.usAPIEndpoint + "/health")

        let cn = await cnMs
        let us = await usMs

        let region: CloudRegion
        if let cn, let us {
            region = cn < us ? .cn : .overseas
        } else if cn != nil {
            region = .cn
        } else {
            region = .overseas
        }

        CloudConfig.currentRegion = region
        logger.info("Region detected: \(region.rawValue) (cn=\(cn ?? -1, format: .fixed(precision: 0))ms, us=\(us ?? -1, format: .fixed(precision: 0))ms)")
        return region
    }

    /// Ping a health endpoint, returning round-trip time in milliseconds or nil on failure.
    private static func ping(_ urlString: String) async -> Double? {
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
