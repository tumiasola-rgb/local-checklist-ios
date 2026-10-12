import SwiftUI
import WidgetKit

@main
struct LocalChecklistWidgets: WidgetBundle {
    var body: some Widget {
        MonthCalendarWidget()
        TodayTasksWidget()
    }
}
