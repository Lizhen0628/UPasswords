import Foundation

// MARK: - CSV 引擎

/// RFC 4180 风格 CSV/TSV 引擎。
enum CSV {
    /// 解析文本为行×列;支持引号包裹、内嵌分隔符/换行,空行被跳过。
    /// - Parameter text: 原始 CSV/TSV 文本
    /// - Returns: 行数组,每行为该行字段数组
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var i = text.startIndex
        let end = text.endIndex
        while i < end {
            let c = text[i]
            if inQuotes {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < end, text[next] == "\"" { field.append("\""); i = next }
                    else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," || c == "\t" {
                row.append(field); field = ""
            } else if c == "\n" {
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else if c != "\r" {
                field.append(c)
            }
            i = text.index(after: i)
        }
        row.append(field)
        if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
        return rows
    }

    /// 导出用转义:字段内引号翻倍并整体包裹(与 rows 解析互逆)。
    static func escape(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
