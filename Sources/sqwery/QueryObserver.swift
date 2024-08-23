import Combine
import Foundation

@MainActor
public class QueryObserver<K: QueryKey>: ObservableObject {
  @Published private(set) var state: RequestState<K.Result> = RequestState()
  var status: RequestStatus<K.Result> { state.status }

  private var cancellable: AnyCancellable?
  private let client: QueryClient
  private let key: K

  init(client: QueryClient, key: K) {
    self.client = client
    self.key = key
  }

  func listen() {
    Task {
      cancellable = await client.subscribe(for: key)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] state in
          self?.state = state
        }
    }
  }

  func invalidate() {
    Task {
      await client.invalidate(key: key)
    }
  }

  func cancel() {
    cancellable?.cancel()
  }
}
