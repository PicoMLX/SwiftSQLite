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
        var objects: [[String: Any]] = []
        objects.reserveCapacity(rs.rows.count)
        for row in rs.rows {
            var object: [String: Any] = [:]
            for (index, column) in rs.columns.enumerated() where index < row.count {
                object[column] = jsonValue(row[index])
            }
            objects.append(object)
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: objects, options: [.sortedKeys]),
            let string = String(data: data, encoding: .utf8)
        else { return "[]\n" }
        return string + "\n"
    }

    private static func jsonValue(_ value: SQLiteValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .integer(let i): return i
        case .real(let d): return d
        case .text(let s): return s
        case .blob(let data): return data.base64EncodedString()
        }
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
