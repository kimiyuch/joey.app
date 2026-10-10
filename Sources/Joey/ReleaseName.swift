import Foundation

/// A readable title parsed from a release file name like "Slow.Horses.S06E03.1080p.HEVC.x265-MeGusta[EZTVx.to].mkv".
struct ReleaseName: Hashable {
    /// The show or movie, e.g. "Slow Horses". The bare file name if nothing could be parsed.
    let title: String
    let year: Int?
    let season: Int?
    let episode: Int?
    /// e.g. "A Bear on a Chain", when the file name has one.
    let episodeTitle: String?
    /// "4K", "1080p", "720p" and so on, when the file name says.
    let quality: String?

    var isEpisode: Bool { episode != nil }

    /// "S06E03", or nil for movies.
    var code: String? {
        guard let season, let episode else { return nil }
        return String(format: "S%02dE%02d", season, episode)
    }

    /// What follows the title in a flat list: "S06E03 · A Bear on a Chain", or the year for movies.
    var detail: String? {
        if isEpisode { return [code, episodeTitle].compactMap(\.self).joined(separator: " · ") }
        return year.map(String.init)
    }

    /// "Slow Horses S06E03", for menus and other single-line places.
    var fullTitle: String {
        [title, isEpisode ? code : year.map(String.init)].compactMap(\.self).joined(separator: " ")
    }

    /// Groups episodes of the same show, even when only some file names include the year.
    var showKey: String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    init(_ url: URL) {
        self.init(fileName: url.deletingPathExtension().lastPathComponent)
    }

    init(fileName: String) {
        // Dots and underscores stand in for spaces in most release names.
        var name = fileName.replacingOccurrences(of: "_", with: " ")
        if !name.contains(" ") || name.firstMatch(of: /\w\.\w+\.\w/) != nil {
            name = Self.dotsToSpaces(name)
        }
        // A leading "[Group]" tag.
        name = name.replacing(/^\s*\[[^\]]*\]\s*/, with: "")
        // After the dots are gone, since Swift's \b sees "01.1080p" as one word.
        quality = Self.quality(in: name)

        let episodeMatch = name.firstMatch(of: /(?i)\bS(\d{1,2})\s?E(\d{1,3})(?:-?E\d{1,3})*\b/)
            ?? name.firstMatch(of: /\b(\d{1,2})x(\d{2,3})\b/)
        if let match = episodeMatch {
            let head = String(name[..<match.range.lowerBound])
            let (title, year) = Self.splitYear(Self.trim(head))
            let rest = Self.trim(Self.beforeTags(String(name[match.range.upperBound...])))
            self.title = title.isEmpty ? fileName : title
            self.year = year
            season = Int(match.1)
            episode = Int(match.2)
            episodeTitle = rest.isEmpty ? nil : rest
            return
        }

        // Movies: everything up to the year or the first quality tag.
        let head = Self.trim(Self.beforeTags(name))
        let (title, year) = Self.splitYear(head)
        self.title = title.isEmpty ? fileName : title
        self.year = year
        season = nil
        episode = nil
        episodeTitle = nil
    }

    private static func quality(in name: String) -> String? {
        if name.firstMatch(of: /(?i)\b(?:2160p|4K|UHD)\b/) != nil { return "4K" }
        return name.firstMatch(of: /(?i)\b(1080|720|576|480)[pi]\b/).map { "\($0.1)p" }
    }

    /// The text before the first quality tag or bracket, e.g. "1080p", "WEB-DL" or "(1080p ATV …)".
    private static func beforeTags(_ text: String) -> String {
        let tags = /(?i)[\[\(\{]|\b(?:2160p|1080p|1080i|720p|576p|480p|4K|UHD|WEB-?DL|WEB-?Rip|WEB|BluRay|Blu-Ray|BDRip|BRRip|HDRip|HDTV|DVDRip|DVD|HEVC|AVC|x26[45]|H ?26[45]|10bit|HDR10?|DV|AAC\d?|DDP?\d|AC3|DTS|REPACK|PROPER|EXTENDED|UNRATED|REMASTERED|IMAX|MULTi|COMPLETE)\b/
        guard let match = text.firstMatch(of: tags) else { return text }
        // A bracketed year like "(2026)" belongs to the title, not the tags.
        if text[match.range.lowerBound...].firstMatch(of: /^[\(\[](?:19|20)\d\d[\)\]]/) != nil {
            let after = text.index(match.range.lowerBound, offsetBy: 6)
            return String(text[..<after]) + beforeTags(String(text[after...]))
        }
        return String(text[..<match.range.lowerBound])
    }

    /// Takes a trailing year off the title: "Star City (2026)" → ("Star City", 2026).
    /// A title that is only a year, like "1917", stays as it is.
    private static func splitYear(_ text: String) -> (String, Int?) {
        guard let match = text.firstMatch(of: /\s[\(\[]?((?:19|20)\d\d)[\)\]]?$/) else { return (text, nil) }
        return (trim(String(text[..<match.range.lowerBound])), Int(match.1))
    }

    /// Keeps the dot in channel counts like "5.1".
    private static func dotsToSpaces(_ text: String) -> String {
        let chars = Array(text)
        return String(chars.indices.map { i in
            guard chars[i] == "." else { return chars[i] }
            let decimal = i > 0 && i + 1 < chars.count && chars[i - 1].isNumber && chars[i + 1].isNumber
                && (i + 2 == chars.count || !chars[i + 2].isNumber)
            return decimal ? "." : " "
        })
    }

    private static func trim(_ text: String) -> String {
        text.replacing(/\s+/, with: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -–—.:,[(").union(.whitespaces))
    }
}
