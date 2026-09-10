import Foundation

/// Kuru's public, unauthenticated token directory — searchable across (almost) every token tradeable on Monad,
/// hundreds of them, most with real logos. This is the broad token list behind the swap picker's search box, so a
/// person can find any Monad asset by symbol, name, or pasted address without it being curated in the app.
///
/// Uses the data host `api.kuru.io` (GET, no auth), distinct from the Flow quote host `ws.kuru.io` the swap engine
/// already uses. Results are cached per query for the session.
public actor KuruTokenListClient {
    private let session: URLSession
    private var cache: [String: [Token]] = [:]

    public init(session: URLSession = .shared) { self.session = session }

    /// Tokens matching `query` — a symbol, a name, or a pasted 0x address. An empty query returns Kuru's default
    /// top list. Returns an empty array on any network/parse failure (the picker falls back to its local universe).
    public func search(_ query: String) async -> [Token] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let cached = cache[key] { return cached }
        guard var components = URLComponents(url: Kuru.dataApi.appending(path: "api/v1/tokens/search"), resolvingAgainstBaseURL: false) else { return [] }
        components.queryItems = [URLQueryItem(name: "q", value: key)]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let json = try? JSONDecoder().decode(JSON.self, from: data) else { return [] }

        // Rank the noisy long tail: an exact ticker/address match first, then verified tokens, keeping Kuru's order
        // within each group — so the real asset surfaces above look-alike scams that merely contain the query.
        let rows = (json["data"]["data"].array ?? []).enumerated().sorted { a, b in
            let (ra, rb) = (Self.rank(a.element, query: key), Self.rank(b.element, query: key))
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)

        var out: [Token] = []
        var seen = Set<Address>()
        for row in rows {
            guard let token = Self.token(from: row), seen.insert(token.address).inserted else { continue }
            out.append(token)
        }
        cache[key] = out
        return out
    }

    /// Lower rank = shown first: 0 exact ticker/address match, 1 verified/strict, 2 everything else.
    private static func rank(_ row: JSON, query: String) -> Int {
        let ticker = (row["ticker"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let address = (row["address"].string ?? "").lowercased()
        if ticker == query || address == query { return 0 }
        if row["is_verified"].bool == true || row["is_strict"].bool == true { return 1 }
        return 2
    }

    /// Maps a Kuru token row onto the app's `Token`. Sanitizes the noisy long tail (names carry leading tabs/emoji)
    /// and accepts `decimal` as either a number (search endpoint) or a string (markets endpoint).
    private static func token(from row: JSON) -> Token? {
        guard let addressString = row["address"].string, let address = Address(addressString) else { return nil }
        let symbol = (row["ticker"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !symbol.isEmpty else { return nil }
        var name = (row["name"].string ?? symbol).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = symbol }
        let decimals = row["decimal"].number.map { Int($0) } ?? Int(row["decimal"].string ?? "") ?? 18
        let logo = row["imageurl"].string.flatMap { URL(string: $0) }
        return Token(address: address, symbol: symbol, name: name, decimals: decimals, logoURL: logo)
    }
}
