import Foundation
import Observation

protocol BindableState {
    associatedtype BindStateType = Void
    var bindings: BindStateType { get set }
}

extension BindableState where BindStateType == Void {
    var bindings: Void {
        get {}
        set {}
    }
}

@MainActor
class StateStoreViewModel<State: BindableState, ViewAction> {
    var context: Context

    var state: State {
        get { context.viewState }
        set { context.viewState = newValue }
    }

    init(initialViewState: State) {
        context = Context(initialViewState: initialViewState)
        context.viewModel = self
    }

    func process(viewAction: ViewAction) {
    }

    func send(viewAction: ViewAction) {
        process(viewAction: viewAction)
    }

    @dynamicMemberLookup
    @MainActor
    @Observable
    final class Context {
        fileprivate weak var viewModel: StateStoreViewModel?

        fileprivate(set) var viewState: State

        subscript<T>(dynamicMember keyPath: WritableKeyPath<State.BindStateType, T>) -> T {
            get { viewState.bindings[keyPath: keyPath] }
            set { viewState.bindings[keyPath: keyPath] = newValue }
        }

        func send(viewAction: ViewAction) {
            viewModel?.process(viewAction: viewAction)
        }

        fileprivate init(initialViewState: State) {
            viewState = initialViewState
        }
    }
}
