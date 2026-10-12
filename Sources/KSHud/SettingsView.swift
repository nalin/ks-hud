import SwiftUI

/// Where finished sessions are posted. Edits are drafts until Save, so a half-typed URL or token is never used.
struct SettingsView: View {
    @ObservedObject var poster: SessionPoster

    @State private var enabled: Bool
    @State private var endpoint: String
    @State private var token: String
    @State private var since: Date
    @State private var keychainError = false

    init(poster: SessionPoster) {
        self.poster = poster
        _enabled = State(initialValue: poster.settings.enabled)
        _endpoint = State(initialValue: poster.settings.endpoint)
        _token = State(initialValue: poster.token)
        _since = State(initialValue: poster.settings.since)
    }

    private var draft: SessionPoster.Settings {
        SessionPoster.Settings(enabled: enabled, endpoint: endpoint.trimmingCharacters(in: .whitespaces),
                               since: Calendar.current.startOfDay(for: since))
    }

    private var changed: Bool { draft != poster.settings || token != poster.token }

    private var problem: String? {
        guard enabled else { return nil }
        if endpoint.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the endpoint URL." }
        if SessionPoster.endpointURL(endpoint) == nil { return "Enter a full URL starting with https://." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Toggle("Post finished sessions", isOn: $enabled)
                    TextField("Endpoint URL", text: $endpoint, prompt: Text("https://example.com/api/workouts"))
                        .disabled(!enabled)
                    SecureField("Token", text: $token, prompt: Text("Optional"))
                        .disabled(!enabled)
                    DatePicker("Send sessions from", selection: $since, in: ...Date(), displayedComponents: .date)
                        .disabled(!enabled)
                } header: {
                    Text("Post sessions to another app")
                } footer: {
                    Text("Each walk is sent as JSON in a POST request once it ends, with the token as an Authorization: Bearer header. The token is kept in your Keychain. Walks are resent with the same id if they change, so the endpoint should update rather than add on a repeat.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if poster.settings.enabled {
                    Section("Status") {
                        statusRow
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Group {
                    if let problem {
                        Text(problem)
                    } else if keychainError {
                        Text("Couldn't save the token to the Keychain.")
                    } else if changed {
                        Text("Unsaved changes")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Revert", action: revert)
                    .disabled(!changed)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!changed || problem != nil)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480)
    }

    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                if let status = poster.status {
                    Label(status.message, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.ok ? Color.green : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(status.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(poster.sending ? "Sending…"
                     : poster.waiting == 0 ? "Up to date"
                     : poster.waiting == 1 ? "1 session waiting" : "\(poster.waiting) sessions waiting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Send Now", action: poster.sendNow)
                .disabled(poster.sending || poster.waiting == 0)
        }
    }

    private func save() {
        keychainError = !poster.apply(draft, token: token)
    }

    private func revert() {
        enabled = poster.settings.enabled
        endpoint = poster.settings.endpoint
        token = poster.token
        since = poster.settings.since
        keychainError = false
    }
}
