import AppKit
import Observation
import SwiftUI

/// Sports preferences use the same store as the live-score watcher. No teams means no polling.
struct SetupSportsPage: View {
    @State private var followed = FootballTeams.load()
    @State private var query = ""
    @State private var sport: Sport = .soccer
    @State private var search = SetupSportsSearch()

    private var request: SetupSportsSearch.Request {
        .init(query: query, sport: sport)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SetupSection(title: "Following \(followed.count) \(followed.count == 1 ? "team" : "teams")") {
                if followed.isEmpty {
                    SetupInlineNote(symbol: "sportscourt", text: "No teams followed. Sports is off.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    ForEach(followed, id: \.key) { team in
                        teamRow(team)
                    }
                }
            }

            SetupSection(title: "Find a team") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Sport", selection: $sport) {
                        ForEach(Sport.allCases, id: \.self) { sport in
                            Text(sport.name).tag(sport)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Sport")

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        TextField("Search for a team", text: $query)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Search for a team")
                        if !query.isEmpty {
                            Button {
                                query = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear team search")
                            .help("Clear team search")
                        }
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
                    }

                    if request.query.count < 2 {
                        Text("Type at least 2 characters to search ESPN.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else if search.isSearching {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel("Searching for teams")
                            Text("Searching \(sport.name) teams…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    } else if search.didSearch && search.results.isEmpty {
                        Text("No \(sport.name) teams found. Try a different name.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)

                ForEach(search.results, id: \.key) { team in
                    teamRow(team)
                }
            }

            SetupInlineNote(
                symbol: "info.circle",
                text: "Scores and schedules come from ESPN. Follow a team for pregame reminders, live scores, and final results. No extra permissions needed."
            )
        }
        .task(id: request) {
            await search.load(request)
        }
        .onDisappear {
            search.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: FootballTeams.changed)) { _ in
            followed = FootballTeams.load()
        }
    }

    private func teamRow(_ team: FootballTeam) -> some View {
        let isFollowed = followed.contains { $0.key == team.key }
        return HStack(spacing: 12) {
            SetupSportsCrest(team: team)
            VStack(alignment: .leading, spacing: 3) {
                Text(team.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(team.abbr.isEmpty ? team.kind.name : "\(team.kind.name) · \(team.abbr)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if isFollowed {
                Button("Remove") {
                    FootballTeams.unfollow(team.key)
                    followed = FootballTeams.load()
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Remove \(team.name)")
                .help("Stop following \(team.name)")
            } else {
                Button("Follow") {
                    FootballTeams.follow(team)
                    followed = FootballTeams.load()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Follow \(team.name)")
                .help("Follow \(team.name)")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Color(nsColor: .separatorColor).opacity(0.5)
                .frame(height: 0.5)
                .padding(.leading, 60)
        }
    }
}

private struct SetupSportsCrest: View {
    let team: FootballTeam

    var body: some View {
        Group {
            if let image = CrestStore.shared.image(team) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 24, height: 24)
            } else {
                Circle()
                    .fill(Color(hex: team.colorHex))
                    .frame(width: 14, height: 14)
            }
        }
        .frame(width: 32, height: 32)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .help("\(team.name) crest from ESPN")
        .accessibilityHidden(true)
    }
}

/// SwiftUI owns the task. This model owns only results, so there is no retained task or observer to clean up.
@MainActor @Observable
final class SetupSportsSearch {
    struct Request: Hashable {
        let query: String
        let sport: Sport

        init(query: String, sport: Sport) {
            self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            self.sport = sport
        }
    }

    private(set) var results: [FootballTeam] = []
    private(set) var isSearching = false
    private(set) var didSearch = false

    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let searchTeams: @Sendable (String) async -> [FootballTeam]

    init(debounce: Duration = .milliseconds(350),
         searchTeams: @escaping @Sendable (String) async -> [FootballTeam] = { await FootballSearch.teams($0) }) {
        self.debounce = debounce
        self.searchTeams = searchTeams
    }

    func load(_ request: Request) async {
        guard !Task.isCancelled else { return }
        let id = UUID()
        requestID = id
        results = []
        isSearching = false
        didSearch = false
        guard request.query.count >= 2 else { return }

        do {
            try await Task.sleep(for: debounce)
        } catch {
            return
        }
        guard !Task.isCancelled, requestID == id else { return }
        isSearching = true
        defer {
            if requestID == id { isSearching = false }
        }

        let found = await searchTeams(request.query)
        guard !Task.isCancelled, requestID == id else { return }
        results = Array(found.filter { $0.kind == request.sport }.prefix(6))
        didSearch = true
    }

    func cancel() {
        requestID = nil
        results = []
        isSearching = false
        didSearch = false
    }
}
