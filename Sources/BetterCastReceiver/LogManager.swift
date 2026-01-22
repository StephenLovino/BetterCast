import SwiftUI

class LogManager: ObservableObject {
    static let shared = LogManager()
    @Published var logs: [String] = []
    
    func log(_ message: String) {
        DispatchQueue.main.async {
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            self.logs.append("[\(timestamp)] \(message)")
            if self.logs.count > 200 {
                self.logs.removeFirst()
            }
            print(message)
        }
    }
}

struct LogView: View {
    @ObservedObject var logManager = LogManager.shared
    
    var body: some View {
        VStack {
            HStack {
                Text("Logs")
                    .font(.caption)
                    .foregroundStyle(.gray)
                Spacer()
                Button(action: {
                    let text = logManager.logs.joined(separator: "\n")
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                    Text("Copy")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .padding(4)
                .background(Color.gray.opacity(0.3))
                .cornerRadius(4)
            }
            .padding(.horizontal)
            
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(logManager.logs, id: \.self) { log in
                        Text(log)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .frame(height: 150)
            .background(Color.black.opacity(0.8))
        }
    }
}
