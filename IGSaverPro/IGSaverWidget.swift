import WidgetKit
import SwiftUI

struct IGSaverEntry: TimelineEntry {
    let date: Date
    let loggedIn: Bool
    let username: String
}

struct IGSaverWidgetProvider: TimelineProvider {
    let serverURL = "https://sam-contracts-merchandise-contractor.trycloudflare.com"

    func placeholder(in context: Context) -> IGSaverEntry {
        IGSaverEntry(date: Date(), loggedIn: true, username: "Conectado")
    }

    func getSnapshot(in context: Context, completion: @escaping (IGSaverEntry) -> Void) {
        completion(IGSaverEntry(date: Date(), loggedIn: true, username: "IG Saver Pro"))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<IGSaverEntry>) -> Void) {
        guard let url = URL(string: "\(serverURL)/api/status") else {
            let entry = IGSaverEntry(date: Date(), loggedIn: false, username: "Offline")
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            var logged = false
            var uname = "Modo Público"
            if let data = data,
               let status = try? JSONDecoder().decode(SessionStatus.self, from: data) {
                logged = status.logged_in
                uname = status.username ?? (logged ? "Sesión Activa" : "Sin Sesión")
            }
            let entry = IGSaverEntry(date: Date(), loggedIn: logged, username: uname)
            let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
            completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
        }.resume()
    }
}

struct IGSaverWidgetEntryView: View {
    var entry: IGSaverWidgetProvider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.pink)
                    .font(.system(size: 20))
                Text("IG Saver Pro")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(entry.loggedIn ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(entry.loggedIn ? "@\(entry.username)" : entry.username)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.gray)
            }

            Spacer()

            Text("📥 Tocar para buscar perfil o guardar link")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.pink)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(Color.pink.opacity(0.2))
                .cornerRadius(8)
        }
        .padding(14)
        .background(Color(red: 0.07, green: 0.07, blue: 0.11))
    }
}

struct IGSaverWidget: Widget {
    let kind: String = "IGSaverWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: IGSaverWidgetProvider()) { entry in
            IGSaverWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("IG Saver Pro Widget")
        .description("Descarga historias anónimas, destacadas, publicaciones y fotos de perfil directo en Fotos.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
