import Foundation

extension Date {
    var relativeDisplay: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: .now)
    }

    var shortDisplay: String {
        let calendar = Calendar.current
        let formatter = DateFormatter()

        if calendar.isDateInToday(self) {
            formatter.dateFormat = "HH:mm"
        } else if calendar.isDateInYesterday(self) {
            return "昨天"
        } else if calendar.isDate(self, equalTo: .now, toGranularity: .year) {
            formatter.dateFormat = "M月d日"
        } else {
            formatter.dateFormat = "yyyy/M/d"
        }

        return formatter.string(from: self)
    }
}
