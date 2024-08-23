import Foundation

public class RequestState<Result>: NSObject {
  var beganFetching: Date?
  var finishedFetching: Date?
  var retryCount: Int = 0
  var status: RequestStatus<Result> = .pending
}

public enum RequestStatus<Result> {
  case success(value: Result)
  case error(error: any Error)
  case pending
  case idle

  var isIdle: Bool {
    if case .idle = self { return true }
    return false
  }

  var isPending: Bool {
    if case .pending = self { return true }
    return false
  }

  var isSuccess: Bool {
    if case .success = self { return true }
    return false
  }

  var isFailure: Bool {
    if case .error = self { return true }
    return false
  }

  var data: Result? {
    if case let .success(value) = self { return value }
    return nil
  }

  var error: Error? {
    if case let .error(error) = self { return error }
    return nil
  }
}
