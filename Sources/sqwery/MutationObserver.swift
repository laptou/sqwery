import Combine
import Foundation

@MainActor
public class MutationObserver<K: MutationKey>: ObservableObject {
  @Published private(set) var state = RequestState<K.Result, K.Progress>()
  var status: RequestStatus<K.Result, K.Progress> { state.status }
  
  private var cancellable: AnyCancellable?
  private let client: MutationClient
  private let key: K

  init(client: MutationClient, key: K) {
    self.client = client
    self.key = key
  }

  func mutate(parameter: K.Parameter) {
    Task {
      cancellable = await client.mutate(key, parameter: parameter)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] state in
          self?.state = state
        }
    }
  }

  func mutateAsync(parameter: K.Parameter) async -> Result<K.Result, Error> {
    let stream = await client.mutate(key, parameter: parameter)
      .receive(on: DispatchQueue.main)
      .values

    for await state in stream {
      switch state.status {
      case let .success(value: value):
        return .success(value)
      case let .error(error: error):
        return .failure(error)
      default: continue
      }
    }

    return .failure(MutationObserverError.canceled)
  }

  func cancel() {
    cancellable?.cancel()
  }
}

public enum MutationObserverError: Error {
  case canceled
}
