import WidgetKit
import SwiftUI

struct IGSaverEntry: TimelineEntry {
    let date: Date
    let loggedIn: Bool
    let username: String
}

struct IGSaverWidgetProvider: TimelineProvider {

    func placeholder(in context: Context) -> IGSaverEntry {
        IGSaverEntry(date: Date(), loggedIn: true, username: "Conectado")
    }

    func getSnapshot(in context: Context, completion: @escaping (IGSaverEntry) -> Void) {
        completion(IGSaverEntry(date: Date(), loggedIn: true, username: "IG Saver Pro"))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<IGSaverEntry>) -> Void) {
        // This source is not an extension target. Never expose another installation's session.
        let entry = IGSaverEntry(date: Date(), loggedIn: false, username: "Abrir IG Saver Pro")
        completion(Timeline(entries: [entry], policy: .never))
    }

}

struct IGSaverWidgetEntryView: View {
    var entry: IGSaverWidgetProvider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.pink)
                Text("IG Saver Pro")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(entry.loggedIn ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(entry.username)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
            }

            Text("Toca para descargar historias o destacadas")
                .font(.system(size: 10))
                .foregroundColor(.gray)
                .lineLimit(2)
        }
        .padding(14)
        .background(Color(red: 0.08, green: 0.08, blue: 0.12))
    }
}

struct IGSaverWidget: Widget {
    let kind: String = "IGSaverWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: IGSaverWidgetProvider()) { entry in
            IGSaverWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("IG Saver Pro Widget")
        .description("Acceso rápido y estado de tu descargador de Instagram.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
