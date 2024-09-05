import Combine
import Foundation

@MainActor
public class MutationObserver<K: MutationKey>: ObservableObject {
  @Published public private(set) var state = RequestState<K.Result, K.Progress>()
  public var status: RequestStatus<K.Result, K.Progress> { state.status }

  private var cancellable: AnyCancellable?
  private let client: MutationClient
  private let key: K

  public init(client: MutationClient, key: K) {
    self.client = client
    self.key = key
  }

  public init(key: K) {
    client = MutationClient.shared
    self.key = key
  }

  public func mutate(_ parameter: K.Parameter) {
    cancellable?.cancel()

    let task = Task {
      for await state in await client.mutate(key, parameter: parameter) {
        self.state = state
      }
    }

    cancellable = AnyCancellable { task.cancel() }
  }

  public func mutateAsync(_ parameter: K.Parameter) async -> Result<K.Result, Error> {
    cancellable?.cancel()

    for await state in await client.mutate(key, parameter: parameter) {
      self.state = state

      switch state.status {
      case let .success(value: value):
        return .success(value)
      case let .error(error: error):
        return .failure(error)
      default: continue
      }
    }

    return .failure(ObserverError.canceled)
  }

  func cancel() {
    cancellable?.cancel()
  }
}

public enum ObserverError: Error {
  case canceled
}
