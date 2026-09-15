import Foundation
import SQLite3

extension HistoryStore {

    /// Re-evaluates all records with cost_usd == 0 in llm_usage_history using current pricing rules.
    public func recalculateZeroCostRecordsIfNeeded() async {
        let selectSQL = """
        SELECT id, provider, model, prompt_tokens, completion_tokens
        FROM llm_usage_history
        WHERE cost_usd = 0.0 AND total_tokens > 0;
        """
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(selectStmt) }

        var updates: [(id: String, newCost: Double)] = []

        while sqlite3_step(selectStmt) == SQLITE_ROW {
            let id = column(selectStmt, 0)
            let provider = column(selectStmt, 1)
            let model = column(selectStmt, 2)
            let prompt = Int(sqlite3_column_int(selectStmt, 3))
            let comp = Int(sqlite3_column_int(selectStmt, 4))

            let calculated = LLMPricingRegistry.calculateCostUSD(
                model: model,
                provider: provider,
                promptTokens: prompt,
                completionTokens: comp
            )

            if calculated > 0 {
                updates.append((id: id, newCost: calculated))
            }
        }

        guard !updates.isEmpty else { return }

        let updateSQL = "UPDATE llm_usage_history SET cost_usd = ? WHERE id = ?;"
        var updateStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(updateStmt) }

        sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
        for u in updates {
            sqlite3_bind_double(updateStmt, 1, u.newCost)
            bind(updateStmt, 2, u.id)
            sqlite3_step(updateStmt)
            sqlite3_reset(updateStmt)
        }
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        NSLog("[HistoryStore] Recalculated cost for %d historical LLM records", updates.count)
    }
}
