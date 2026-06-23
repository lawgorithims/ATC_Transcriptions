import SwiftUI

/// Placeholder console shown by the skeleton build. The real UI — a SwiftUI port
/// of the browser console (Cockpit/Day/Night themes, handshake/proof-of-life/stream
/// pills, transcript list, latency + host sidebar, settings sheet) — replaces this
/// in the UI phase. Kept dependency-free so the first build is green.
struct ConsoleView: View {
    var body: some View {
        ZStack {
            // Cockpit theme background (mirrors --bg in server/static/styles.css).
            Color(red: 0x0b / 255, green: 0x11 / 255, blue: 0x17 / 255)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    Text("ATC")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.9))
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading) {
                        Text("ATC_Transcribe").font(.title2.bold())
                        Text("Live air-traffic-control transcription · on-device")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Text("Native iOS port — skeleton build")
                    .font(.headline).foregroundStyle(.secondary)
                Text("Deterministic core (context + corrector) is wired. Audio, "
                     + "WhisperKit, and the full console UI come next.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }
            .padding()
            .foregroundStyle(.white)
        }
    }
}

#Preview {
    ConsoleView()
}
