import Foundation
import SwiftSQLiteKit

/// CLI output formats (PLAN.md §10).
public enum OutputMode: String, Sendable, CaseIterable {
    case list
    case csv
    case json
    case column
    case line
}

/// Mutable rendering options. Some can change mid-session via dot-commands
/// (`.mode`, `.headers`, `.separator`, `.nullvalue`).
struct OutputOptions: Sendable {
    var mode: OutputMode = .list
    var header: Bool = false
    var separator: String = "|"
    var nullValue: String = ""
}

/// Per-invocation session state threaded through input processing. A
/// reference type so dot-commands can mutate `.mode`/`.headers`/etc.
/// without passing `inout` across `async` calls.
final class SessionState {
    var options: OutputOptions
    /// The database location, for `.databases`.
    let databasePath: String

    init(options: OutputOptions, databasePath: String) {
        self.options = options
        self.databasePath = databasePath
    }
}

/// Renders a `ResultSet` to text per the active `OutputMode`.
enum ResultRenderer {
    static func render(_ resultSet: ResultSet, options: OutputOptions) -> String {
        switch options.mode {
        case .list: return renderList(resultSet, options)
        case .csv: return renderCSV(resultSet, options)
        case .json: return renderJSON(resultSet, options)
        case .column: return renderColumn(resultSet, options)
        case .line: return renderLine(resultSet, options)
        }
    }

    // MARK: list

    private static func renderList(_ rs: ResultSet, _ options: OutputOptions) -> String {
        var lines: [String] = []
        if options.header {
            lines.append(rs.columns.joined(separator: options.separator))
        }
        for row in rs.rows {
            lines.append(row.map { cell($0, options) }.joined(separator: options.separator))
        }
        return joinedLines(lines)
    }

    // MARK: csv

    private static func renderCSV(_ rs: ResultSet, _ options: OutputOptions) -> String {
        var lines: [String] = []
        if options.header {
            lines.append(rs.columns.map(csvField).joined(separator: ","))
        }
        for row in rs.rows {
            lines.append(row.map { csvField(cell($0, options)) }.joined(separator: ","))
        }
        return joinedLines(lines)
    }

    private static func csvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"")
            || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    // MARK: json

    private static func renderJSON(_ rs: ResultSet, _ options: OutputOptions) -> String {
        // Assemble objects by hand rather than via `[String: Any]`: a dictionary
        // silently drops duplicate column names — common with `SELECT *` over a
        // join (`SELECT a.id, b.id …`) — and reorders keys. Real sqlite3 `-json`
        // preserves both column order and duplicate keys, so we do too.
        var objects: [String] = []
        objects.reserveCapacity(rs.rows.count)
        for row in rs.rows {
            var pairs: [String] = []
            pairs.reserveCapacity(rs.columns.count)
            for (index, column) in rs.columns.enumerated() {
                let value = index < row.count ? row[index] : .null
                pairs.append(jsonString(column) + ":" + jsonValue(value))
            }
            objects.append("{" + pairs.joined(separator: ",") + "}")
        }
        return "[" + objects.joined(separator: ",") + "]\n"
    }

    /// One cell as a JSON literal (string / number / null / base64 blob).
    private static func jsonValue(_ value: SQLiteValue) -> String {
        switch value {
        case .null: return "null"
        case .integer(let i): return String(i)
        case .real(let d):
            // JSON can't represent Infinity/NaN; emit them as strings so a
            // single non-finite cell doesn't corrupt the whole document.
            return d.isFinite ? jsonNumber(d) : jsonString(String(d))
        case .text(let s): return jsonString(s)
        case .blob(let data): return jsonString(data.base64EncodedString())
        }
    }

    /// A finite `Double` as a JSON number, reusing Foundation's formatting for
    /// parity with the previous serializer (e.g. `1.0` -> `1`, `0.1` -> `0.1`).
    private static func jsonNumber(_ d: Double) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [d]),
           let s = String(data: data, encoding: .utf8) {
            return String(s.dropFirst().dropLast())   // strip the array's [ ]
        }
        return String(d)
    }

    /// Escape a string as a JSON string literal, including the quotes.
    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20:
                out += String(format: "\\u%04x", c.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    // MARK: column

    private static func renderColumn(_ rs: ResultSet, _ options: OutputOptions) -> String {
        let bodies = rs.rows.map { row in row.map { cell($0, options) } }
        var widths = rs.columns.map { $0.count }
        for row in bodies {
            for (index, value) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], value.count)
            }
        }
        var lines: [String] = []
        if options.header {
            let headerCells = zip(rs.columns, widths).map { column, width in
                padRight(column, to: width)
            }
            lines.append(headerCells.joined(separator: "  "))
            let divider = widths.map { String(repeating: "-", count: $0) }
            lines.append(divider.joined(separator: "  "))
        }
        for row in bodies {
            let padded = row.enumerated().map { index, value in
                padRight(value, to: index < widths.count ? widths[index] : value.count)
            }
            lines.append(trimTrailing(padded.joined(separator: "  ")))
        }
        return joinedLines(lines)
    }

    private static func trimTrailing(_ value: String) -> String {
        var end = value.endIndex
        while end > value.startIndex {
            let previous = value.index(before: end)
            if value[previous] == " " { end = previous } else { break }
        }
        return String(value[value.startIndex..<end])
    }

    // MARK: line

    private static func renderLine(_ rs: ResultSet, _ options: OutputOptions) -> String {
        let width = rs.columns.map { $0.count }.max() ?? 0
        var blocks: [String] = []
        for row in rs.rows {
            var lines: [String] = []
            for (index, column) in rs.columns.enumerated() where index < row.count {
                lines.append("\(padLeft(column, to: width)) = \(cell(row[index], options))")
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        guard !blocks.isEmpty else { return "" }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: cell

    private static func cell(_ value: SQLiteValue, _ options: OutputOptions) -> String {
        switch value {
        case .null: return options.nullValue
        case .integer(let i): return String(i)
        case .real(let d): return formatReal(d)
        case .text(let s): return s
        case .blob(let data): return blobLiteral(data)
        }
    }

    private static func formatReal(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(format: "%.1f", value)
        }
        return String(value)
    }

    private static func joinedLines(_ lines: [String]) -> String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private static func padRight(_ value: String, to width: Int) -> String {
        value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
    }

    private static func padLeft(_ value: String, to width: Int) -> String {
        value.count >= width ? value : String(repeating: " ", count: width - value.count) + value
    }
}

/// A SQL-literal / hex rendering of a blob (`x'..'`), shared by the
/// renderer and `.dump`.
func blobLiteral(_ data: Data) -> String {
    "x'" + data.map { String(format: "%02x", $0) }.joined() + "'"
}
