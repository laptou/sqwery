import Foundation

public struct RequestState<Result, Progress> {
  var beganFetching: Date?
  var finishedFetching: Date?
  var retryCount: Int = 0
  public var queryStatus: QueryStatus<Result, Progress> = .idle
  public var fetchStatus: FetchStatus = .idle
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
