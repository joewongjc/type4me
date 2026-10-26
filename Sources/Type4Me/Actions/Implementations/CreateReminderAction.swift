import Foundation

struct CreateReminderAction: MacAction {
    let name = "create_reminder"
    let description = "Create a reminder in Apple Reminders. Optionally specify a due date/time and list name."
    let parametersSchema: [String: String] = [
        "title": "The reminder text (required)",
        "due":   "Optional due date/time, e.g. \"in 2 minutes\", \"in 1 hour\", \"tomorrow 9am\", \"2025-06-01 09:00\"",
        "list":  "Optional Reminders list name; defaults to the default Reminders list",
    ]

    func execute(args: [String: Any]) async -> MacActionResult {
        guard let title = args["title"] as? String, !title.isEmpty else {
            return .failure(L("缺少提醒内容", "Missing reminder title"))
        }
        let due  = (args["due"]  as? String) ?? ""
        let list = (args["list"] as? String) ?? ""

        let safeTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let safeList  = (list.isEmpty ? "Reminders" : list)
            .replacingOccurrences(of: "\"", with: "\\\"")

        var props = "name:\"\(safeTitle)\""
        if !due.isEmpty {
            props += ", due date:\(appleScriptDateExpression(from: due))"
        }

        let script = """
        tell application "Reminders"
            tell list "\(safeList)"
                make new reminder with properties {\(props)}
            end tell
        end tell
        """

        do {
            _ = try await AppleScriptRunner.runScript(script, timeoutSeconds: 20)
            let preview = title.count > 30 ? String(title.prefix(30)) + "…" : title
            return .ok(L("提醒已创建：\(preview)", "Reminder created: \(preview)"))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Converts a natural-language due string to an AppleScript date expression.
    ///
    /// - "in N minutes/hours/days/weeks" → `(current date) + <seconds>`
    ///   This form is locale-safe because it avoids date string parsing entirely.
    /// - Absolute phrasing ("tomorrow 9am", ISO dates) → NSDataDetector → formatted literal.
    /// - Fallback: pass through as a raw date literal (best-effort).
    private func appleScriptDateExpression(from due: String) -> String {
        let lower = due.lowercased()

        let relativeUnits: [(pattern: String, seconds: Int)] = [
            (#"in (\d+) ?second"#, 1),
            (#"in (\d+) ?minute"#, 60),
            (#"in (\d+) ?hour"#, 3_600),
            (#"in (\d+) ?day"#, 86_400),
            (#"in (\d+) ?week"#, 604_800),
        ]
        for (pattern, perUnit) in relativeUnits {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
                  let numRange = Range(match.range(at: 1), in: lower),
                  let n = Int(lower[numRange])
            else { continue }
            return "(current date) + \(n * perUnit)"
        }

        // Absolute natural-language date → NSDataDetector
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: due, range: NSRange(due.startIndex..., in: due)),
           let date = match.date {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "MM/dd/yyyy HH:mm:ss"
            return "date \"\(fmt.string(from: date))\""
        }

        // Last resort: pass through (works if user typed an AppleScript-compatible string)
        let safe = due.replacingOccurrences(of: "\"", with: "\\\"")
        return "date \"\(safe)\""
    }
}
