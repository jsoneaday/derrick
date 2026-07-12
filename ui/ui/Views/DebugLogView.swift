import SwiftUI

struct DebugLogView: View {
    @EnvironmentObject var logStore: LogStore

    var body: some View {
        VStack(alignment: .leading) {
            Text("Logs")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(logStore.entries) { entry in
                        HStack {
                            Text(entry.timestamp, style: .time)
                            Text("[\(entry.category)]")
                            Text(entry.message)
                        }
                    }
                }
            }
        }
        .padding()
    }
}
