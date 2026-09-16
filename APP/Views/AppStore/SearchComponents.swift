import SwiftUI
import Combine

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var suggestions: [String] = []
    @Published var isFetchingSuggestions = false
    @Published var isFocused = false

    var onSuggestionsNeeded: (String) async -> [String] = { _ in [] }

    private let debounceDelay: TimeInterval = 0.1
    private var debounceTask: Task<Void, Never>?
    private let suggestionsCache = LRUCache<String, [String]>(capacity: 50)

    func onSearchTextChanged(_ text: String) {
        debounceTask?.cancel()

        guard !text.isEmpty else {
            suggestions = []
            return
        }

        if let cached = suggestionsCache.value(forKey: text) {
            suggestions = cached
            return
        }

        debounceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(debounceDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await fetchSuggestions(for: text)
        }
    }

    func onFocusedChanged(_ focused: Bool) {
        self.isFocused = focused

        if focused, !searchText.isEmpty, suggestions.isEmpty {
            if let cached = suggestionsCache.value(forKey: searchText) {
                suggestions = cached
            }
        }
    }

    func clearSearch() {
        searchText = ""
        suggestions = []
        debounceTask?.cancel()
    }

    private func fetchSuggestions(for term: String) async {
        isFetchingSuggestions = true
        defer { isFetchingSuggestions = false }

        let results = await onSuggestionsNeeded(term)

        guard !Task.isCancelled else { return }

        suggestionsCache.setValue(results, forKey: term)
        suggestions = results
    }
}

struct SearchInputView: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    @FocusState private var isInputFocused: Bool

    var placeholder: String = "search_placeholder".localized
    var onSubmit: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.secondary)

            TextField(placeholder, text: $text)
                .font(.body)
                .focused($isInputFocused)
                .onSubmit {
                    onSubmit?()
                }

            if !text.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        text = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.gray.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    isInputFocused ? .blue : Color.clear,
                    lineWidth: 2
                )
        )
        .onChange(of: isInputFocused) { _, newValue in
            isFocused = newValue
        }
    }
}

struct SearchSuggestionsListView: View {
    let suggestions: [String]
    var isLoading: Bool = false
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading && suggestions.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding(.vertical, 16)
                    Spacer()
                }
            } else {
                ForEach(suggestions.indices, id: \.self) { index in
                    let suggestion = suggestions[index]
                    Button(action: {
                        onSelect(suggestion)
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)

                            Text(suggestion)
                                .font(.body)
                                .foregroundColor(.primary)
                                .lineLimit(1)

                            Spacer()

                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())

                    if index < suggestions.count - 1 {
                        Divider()
                            .padding(.leading, 44)
                    }
                }
            }
        }
        .background(Color(.systemBackground))
    }
}
