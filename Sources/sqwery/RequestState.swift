import Foundation

public struct RequestState<Result, Progress> {
  var beganFetching: Date?
  var finishedFetching: Date?
  var retryCount: Int = 0
  var invalidated: Bool = false

  public var queryStatus: QueryStatus<Result, Progress> = .idle
  public var fetchStatus: FetchStatus = .idle
}

class AnyRequestState: NSObject {
  var base: Any

  private var _beganFetching: () -> Date?
  private var _finishedFetching: () -> Date?
  private var _retryCount: () -> Int
  private var _invalidated: () -> Bool
  private var _setInvalidated: (Bool) -> Void

  public init(_ state: RequestState<some Any, some Any>) {
    base = state
    _beganFetching = { state.beganFetching }
    _finishedFetching = { state.finishedFetching }
    _retryCount = { state.retryCount }
    _invalidated = { state.invalidated }
    weak var this: AnyRequestState?

    _setInvalidated = { newValue in
      var mutableState = state
      mutableState.invalidated = newValue
      this?.base = mutableState
    }

    super.init()

    this = self
  }

  public var beganFetching: Date? { _beganFetching() }
  public var finishedFetching: Date? { _finishedFetching() }
  public var retryCount: Int { _retryCount() }
  public var invalidated: Bool {
    get { _invalidated() }
    set { _setInvalidated(newValue) }
  }

  public func unwrap<Result, Progress>() -> RequestState<Result, Progress>? {
    base as? RequestState<Result, Progress>
  }
}

// Extension to add convenience initializer to RequestState
extension RequestState {
  var eraseToAnyRequestState: AnyRequestState {
    AnyRequestState(self)
  }
}

public enum FetchStatus {
  case fetching
  case idle
}

public enum QueryStatus<Result, Progress> {
  case success(value: Result)
  case error(error: any Error)
  case pending(progress: Progress?)
  case idle

  public var isIdle: Bool {
    if case .idle = self { return true }
    return false
  }

  public var isPending: Bool {
    if case .pending = self { return true }
    return false
  }

  public var isSuccess: Bool {
    if case .success = self { return true }
    return false
  }

  public var isFailure: Bool {
    if case .error = self { return true }
    return false
  }

  public var data: Result? {
    if case let .success(value) = self { return value }
    return nil
  }

  public var error: Error? {
    if case let .error(error) = self { return error }
    return nil
  }
}
