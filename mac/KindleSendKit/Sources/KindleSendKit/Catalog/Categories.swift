import Foundation

public enum BookCategory: String, CaseIterable, Sendable, Identifiable {
    case popular, fiction, scienceFiction, mystery, philosophy, history, poetry, childrens

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .popular: "Popular"
        case .fiction: "Fiction"
        case .scienceFiction: "Science Fiction"
        case .mystery: "Mystery"
        case .philosophy: "Philosophy"
        case .history: "History"
        case .poetry: "Poetry"
        case .childrens: "Children's"
        }
    }

    /// Matched as prefixes of Gutenberg bookshelf values.
    public var gutenbergShelves: [String] {
        switch self {
        case .popular: []
        case .fiction:
            ["Category: Novels", "Category: Short Stories", "Category: Adventure",
             "Category: Romance", "Category: Historical Novels"]
        case .scienceFiction: ["Category: Science-Fiction & Fantasy"]
        case .mystery: ["Category: Crime, Thrillers and Mystery"]
        case .philosophy: ["Category: Philosophy & Ethics"]
        case .history: ["Category: History"]
        case .poetry: ["Category: Poetry"]
        case .childrens: ["Category: Children & Young Adult Reading"]
        }
    }

    /// Standard Ebooks subject slugs, matched exactly.
    public var standardEbooksSubjects: [String] {
        switch self {
        case .popular: []
        case .fiction: ["fiction"]
        case .scienceFiction: ["science-fiction", "fantasy"]
        case .mystery: ["mystery"]
        case .philosophy: ["philosophy"]
        case .history: ["history"]
        case .poetry: ["poetry"]
        case .childrens: ["childrens"]
        }
    }

    public func matches(_ e: Edition) -> Bool {
        if self == .popular { return true }
        switch e.source {
        case .gutenberg:
            return e.subjects.contains { s in gutenbergShelves.contains { s.hasPrefix($0) } }
        case .standardEbooks:
            return e.subjects.contains { standardEbooksSubjects.contains($0) }
        }
    }

    /// A work belongs to a category when any of its editions does.
    public func matches(_ w: Work) -> Bool { w.editions.contains(where: matches) }
}
