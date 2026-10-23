import Foundation

/// A generic board from the box's GET /bridge/board/<name>: sections of labelled bars. Whoever
/// owns the data maps it into this shape server-side; the widgets only render it.
struct Board: Codable, Sendable, Equatable {
    struct Row: Codable, Sendable, Equatable {
        enum State: String, Codable, Sendable { case ok, over, stalled, idle }

        let label: String
        var detail: String?
        /// `#rgb` or `#rrggbb`: the row's stripe and bar.
        var color: String?
        /// 0..1 solid fill; above 1 draws a full bar.
        var bar: Double?
        /// 0..1 faded layer behind the fill.
        var barFaded: Double?
        var value: String?
        var state: State?
        var url: String?

        enum CodingKeys: String, CodingKey {
            case label, detail, color, bar, value, state, url
            case barFaded = "bar_faded"
        }

        init(label: String, detail: String? = nil, color: String? = nil, bar: Double? = nil, barFaded: Double? = nil,
             value: String? = nil, state: State? = nil, url: String? = nil) {
            self.label = label
            self.detail = detail
            self.color = color
            self.bar = bar
            self.barFaded = barFaded
            self.value = value
            self.state = state
            self.url = url
        }

        /// An unknown state (a newer box) reads as nil, not a failed decode of the whole board.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decode(String.self, forKey: .label)
            detail = try c.decodeIfPresent(String.self, forKey: .detail)
            color = try c.decodeIfPresent(String.self, forKey: .color)
            bar = try c.decodeIfPresent(Double.self, forKey: .bar)
            barFaded = try c.decodeIfPresent(Double.self, forKey: .barFaded)
            value = try c.decodeIfPresent(String.self, forKey: .value)
            state = (try? c.decodeIfPresent(String.self, forKey: .state)).flatMap { $0.flatMap(State.init(rawValue:)) }
            url = try c.decodeIfPresent(String.self, forKey: .url)
        }

        /// Solid fill, clamped to 0...1; `over` is always full.
        var fill: Double { state == .over ? 1 : Self.clamp(bar) }
        var fadedFill: Double { Self.clamp(barFaded) }
        /// Stalled and idle rows draw grey instead of their colour.
        var isMuted: Bool { state == .stalled || state == .idle }

        static func clamp(_ value: Double?) -> Double {
            guard let value, value.isFinite else { return 0 }
            return min(max(value, 0), 1)
        }

        /// `#rgb` / `#rrggbb` → 0xRRGGBB; anything else nil.
        var rgb: UInt32? { Self.rgb(color) }

        static func rgb(_ hex: String?) -> UInt32? {
            guard var digits = hex?.trimmingCharacters(in: .whitespaces), digits.hasPrefix("#") else { return nil }
            digits.removeFirst()
            if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
            return value
        }
    }

    struct Section: Codable, Sendable, Equatable {
        var title: String?
        var rows: [Row]
    }

    var title: String?
    var updatedAt: String?
    var sections: [Section]

    enum CodingKeys: String, CodingKey {
        case title, sections
        case updatedAt = "updated_at"
    }

    /// The same board apart from `updated_at`: what the widget would draw differently.
    func sameContent(as other: Board) -> Bool {
        title == other.title && sections == other.sections
    }

    // MARK: Layout

    /// One line of a board widget: a section heading or a row.
    enum Line: Equatable, Sendable {
        case heading(String)
        case row(Row)
    }

    /// The lines that fit in `limit`, in order, headings included (a heading is only shown with
    /// at least one of its rows, and only when there is more than one section or `headings`);
    /// plus how many rows were left out.
    func lines(limit: Int, headings: Bool = true) -> (lines: [Line], hidden: Int) {
        var out: [Line] = []
        var hidden = 0
        let showHeadings = headings && sections.count > 1
        for section in sections {
            var rows = section.rows[...]
            let heading = showHeadings ? section.title.flatMap { $0.isEmpty ? nil : $0 } : nil
            let need = heading == nil ? 1 : 2
            if !rows.isEmpty, out.count + need <= limit {
                if let heading { out.append(.heading(heading)) }
                while let row = rows.first, out.count < limit {
                    out.append(.row(row))
                    rows = rows.dropFirst()
                }
            }
            hidden += rows.count
        }
        return (out, hidden)
    }

    /// Sections split into `count` columns, each roughly the same number of lines.
    func columns(_ count: Int) -> [Board] {
        guard count > 1, sections.count > 1 else { return [self] }
        let total = sections.reduce(0) { $0 + $1.rows.count + 1 }
        var columns: [[Section]] = [[]]
        var filled = 0
        for section in sections {
            let size = section.rows.count + 1
            if !columns[columns.count - 1].isEmpty, columns.count < count,
               filled + size / 2 > total * columns.count / count {
                columns.append([])
            }
            columns[columns.count - 1].append(section)
            filled += size
        }
        return columns.map { Board(title: title, updatedAt: updatedAt, sections: $0) }
    }

    static let sample = Board(title: "Board", updatedAt: nil, sections: [
        Section(title: "Lanes", rows: [
            Row(label: "cyan", detail: "Mini · Building widgets", color: "#00d7ff", bar: 0.25,
                value: "24m / 98m", state: .ok),
            Row(label: "amber", detail: "Box · Migrating the DB", color: "#ffb000", bar: 1.2,
                value: "130m / 90m", state: .over),
            Row(label: "lime", detail: "Mini · Waiting on review", color: "#7cff4f", bar: 0.6,
                value: "36m / 60m", state: .stalled),
        ]),
        Section(title: "Usage", rows: [
            Row(label: "MAX", detail: "resets Tue 08:00", color: "#888888", bar: 0.31, barFaded: 0.12,
                value: "31%", state: .ok),
        ]),
    ])
}

/// What GET /bridge/board/<name> answers.
struct BoardResponse: Decodable, Sendable {
    let board: Board
    let ageSeconds: Double

    enum CodingKeys: String, CodingKey {
        case board
        case ageSeconds = "age_s"
    }
}

/// A board as last fetched: kept in the App Group by the widget (what it is showing), read by
/// the app to decide whether a fresh fetch is worth a timeline reload.
struct BoardSnapshot: Codable, Sendable, Equatable {
    var name: String
    var board: Board
    /// When the box received this board (fetch time minus `age_s`).
    var receivedAt: Date
    var fetchedAt: Date

    static let staleAfter: TimeInterval = 180
    /// The app reloads an unchanged board once the widget's copy is this old, so a box that
    /// keeps posting the same board never shows as stale.
    static let refreshAfter: TimeInterval = 150

    init(name: String, board: Board, receivedAt: Date, fetchedAt: Date) {
        self.name = name
        self.board = board
        self.receivedAt = receivedAt
        self.fetchedAt = fetchedAt
    }

    init(name: String, response: BoardResponse, now: Date = Date()) {
        self.init(name: name, board: response.board,
                  receivedAt: now.addingTimeInterval(-max(0, response.ageSeconds)), fetchedAt: now)
    }

    func age(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(receivedAt)) }
    func isStale(at now: Date) -> Bool { age(at: now) > Self.staleAfter }
    /// When this snapshot turns stale.
    var staleAt: Date { receivedAt.addingTimeInterval(Self.staleAfter) }

    /// Whether the widget showing `shown` should be reloaded now that `fresh` was fetched:
    /// the content changed, or the shown copy is about to go stale while the box's is not.
    static func needsReload(shown: BoardSnapshot?, fresh: BoardSnapshot, now: Date = Date()) -> Bool {
        guard let shown else { return true }
        if !shown.board.sameContent(as: fresh.board) { return true }
        return shown.age(at: now) > refreshAfter && fresh.receivedAt > shown.receivedAt.addingTimeInterval(1)
    }

    static func decode(_ data: Data) throws -> BoardSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BoardSnapshot.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// `[a-z0-9][a-z0-9_-]{0,31}`, as the box accepts.
enum BoardName {
    static let fallback = "muster"

    static func normalized(_ raw: String?) -> String {
        let name = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return isValid(name) ? name : fallback
    }

    static func isValid(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-z0-9][a-z0-9_-]{0,31}/) != nil
    }
}

// MARK: Row tap → the app opens the row's URL

/// A row tap goes through the app (`bridge://board/open?u=<url>`), which opens the URL: a widget
/// link to another app's scheme is not reliably opened by the system itself.
enum BoardRoute {
    static let scheme = "bridge"
    static let host = "board"

    static func url(for target: String?) -> URL? {
        guard let target, let parsed = URL(string: target), let scheme = parsed.scheme?.lowercased(),
              !["bridge", "bridge-widget"].contains(scheme) else { return nil }
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = host
        components.path = "/open"
        components.queryItems = [.init(name: "u", value: parsed.absoluteString)]
        return components.url
    }

    /// `bridge://board/open?u=<url>` → `<url>`; anything else nil.
    static func target(from url: URL) -> URL? {
        guard url.scheme == scheme, url.host() == host,
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "u" })?.value,
              let target = URL(string: raw), let targetScheme = target.scheme?.lowercased(),
              !["bridge", "bridge-widget"].contains(targetScheme) else { return nil }
        return target
    }
}

// MARK: Fetch and keep

extension SharedStore {
    static let boardFetchTimeout: TimeInterval = 5

    static func boardURL(_ name: String) -> URL? {
        guard let group = appGroup,
              let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return dir.appending(path: "board-\(BoardName.normalized(name)).json")
    }

    static func loadBoard(_ name: String) -> BoardSnapshot? {
        guard let url = boardURL(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? BoardSnapshot.decode(data)
    }

    static func save(_ board: BoardSnapshot) throws {
        guard let url = boardURL(board.name) else { return }
        try board.encoded().write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// GET /bridge/board/<name> with the shared credentials. nil on any failure (404 included).
    static func fetchBoard(_ name: String, now: Date = Date()) async -> BoardSnapshot? {
        let name = BoardName.normalized(name)
        guard let box = boxCredentials() else { return nil }
        var request = URLRequest(url: box.url.appending(path: "bridge/board/\(name)"), timeoutInterval: boardFetchTimeout)
        request.setValue("Bearer \(box.token)", forHTTPHeaderField: "Authorization")
        request.setValue(box.device, forHTTPHeaderField: "X-Bridge-Device")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(BoardResponse.self, from: data) else { return nil }
        return BoardSnapshot(name: name, response: decoded, now: now)
    }
}
