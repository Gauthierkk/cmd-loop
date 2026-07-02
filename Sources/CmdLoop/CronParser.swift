import Foundation


// MARK: - Cron Parser

enum CronError: Error {
    case invalidFormat
    case invalidField(String)
}

struct CronParser {
    let minutes: Set<Int>
    let hours: Set<Int>
    let daysOfMonth: Set<Int>
    let months: Set<Int>
    let daysOfWeek: Set<Int>

    init(_ expression: String) throws {
        let fields = expression.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard fields.count == 5 else { throw CronError.invalidFormat }
        minutes = try Self.parseField(String(fields[0]), range: 0...59)
        hours = try Self.parseField(String(fields[1]), range: 0...23)
        daysOfMonth = try Self.parseField(String(fields[2]), range: 1...31)
        months = try Self.parseField(String(fields[3]), range: 1...12)
        daysOfWeek = try Self.parseField(String(fields[4]), range: 0...6)
    }

    static func parseField(_ field: String, range: ClosedRange<Int>) throws -> Set<Int> {
        if field == "*" {
            return Set(range)
        }
        if field.hasPrefix("*/") {
            guard let step = Int(field.dropFirst(2)), step > 0 else {
                throw CronError.invalidField(field)
            }
            return Set(stride(from: range.lowerBound, through: range.upperBound, by: step))
        }
        var result = Set<Int>()
        for part in field.split(separator: ",") {
            if part.contains("-") {
                let bounds = part.split(separator: "-")
                guard bounds.count == 2,
                      let lo = Int(bounds[0]), let hi = Int(bounds[1]),
                      range.contains(lo), range.contains(hi), lo <= hi
                else { throw CronError.invalidField(field) }
                result.formUnion(lo...hi)
            } else {
                guard let val = Int(part), range.contains(val)
                else { throw CronError.invalidField(field) }
                result.insert(val)
            }
        }
        return result
    }

}
