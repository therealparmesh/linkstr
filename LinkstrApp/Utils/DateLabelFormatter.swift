import Foundation

enum DateLabelFormatter {
  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate("h:mm a")
    return formatter
  }()

  private static let weekdayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate("EEE")
    return formatter
  }()

  private static let monthDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate("MMM d")
    return formatter
  }()

  private static let shortDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.dateStyle = .short
    formatter.timeStyle = .none
    return formatter
  }()

  private static let weekdayTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate("EEE h:mm a")
    return formatter
  }()

  private static let monthDayTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate("MMM d h:mm a")
    return formatter
  }()

  private static let shortDateTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter
  }()

  static func listTimestamp(for date: Date, now: Date = .now, calendar: Calendar = .current)
    -> String
  {
    if calendar.isDateInToday(date) {
      return timeFormatter.string(from: date)
    }
    if calendar.isDateInYesterday(date) {
      return "Yesterday"
    }
    if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
      return weekdayFormatter.string(from: date)
    }
    if calendar.isDate(date, equalTo: now, toGranularity: .year) {
      return monthDayFormatter.string(from: date)
    }
    return shortDateFormatter.string(from: date)
  }

  static func messageTimestamp(
    for date: Date, now: Date = .now, calendar: Calendar = .current
  ) -> String {
    if calendar.isDateInToday(date) {
      return timeFormatter.string(from: date)
    }
    if calendar.isDateInYesterday(date) {
      return "Yesterday, \(timeFormatter.string(from: date))"
    }
    if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
      return weekdayTimeFormatter.string(from: date)
    }
    if calendar.isDate(date, equalTo: now, toGranularity: .year) {
      return monthDayTimeFormatter.string(from: date)
    }
    return shortDateTimeFormatter.string(from: date)
  }
}

extension Date {
  var linkstrListTimestampLabel: String {
    DateLabelFormatter.listTimestamp(for: self)
  }

  var linkstrMessageTimestampLabel: String {
    DateLabelFormatter.messageTimestamp(for: self)
  }
}
