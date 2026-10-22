// The length rule every notification the app posts must meet.
//
// iOS shows about six lines of a notification, even when you press and hold it, and cuts the rest
// without a "more" control. Build 86's illness alert (a sentence per vital, then a blank line and a
// 190-character disclaimer) lost its own caveat and the whole disclaimer that way on a real phone.
//
// THE RULE: a notification's posted body, worst case, wraps to at most `maxLines` lines at
// `lineWidth` characters. 42 is narrower than a current iPhone at the default text size (~49 on the
// phone the cut was seen on), so the budget holds on smaller screens too. Every posting site keeps
// its copy in a pure function, and `NotificationBudgetTests` (app) checks each one's worst case,
// with a source scan that fails when a new posting site appears without joining that test.
//
// Pure (no Apple frameworks) so it unit-tests on the CLI.

import Foundation

public enum NotificationBudget {
    /// Characters per line the budget assumes.
    public static let lineWidth = 42
    /// Most lines a posted body may wrap to.
    public static let maxLines = 5

    /// Greedy word wrap, the way a label lays plain text out: each "\n" starts a new line, a word
    /// longer than the line takes a line of its own.
    public static func wrappedLines(_ text: String, width: Int = lineWidth) -> Int {
        text.components(separatedBy: "\n").reduce(0) { total, paragraph in
            var lines = 1, current = 0
            for word in paragraph.split(separator: " ") {
                let needed = current == 0 ? word.count : current + 1 + word.count
                if needed > width && current > 0 {
                    lines += 1
                    current = word.count
                } else {
                    current = needed
                }
            }
            return total + lines
        }
    }

    /// True when `body` meets the rule.
    public static func fits(_ body: String) -> Bool {
        wrappedLines(body) <= maxLines
    }
}
