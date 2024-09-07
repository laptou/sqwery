import Combine
import Foundation

@MainActor
public class QueryObserver<K: QueryKey>: ObservableObject {
  @Published public private(set) var state: RequestState<K.Result, Void> = RequestState()
  public var status: RequestStatus<K.Result, Void> { state.status }

  private var cancellable: AnyCancellable?
  private let client: QueryClient
  private let key: K

  init(client: QueryClient, key: K) {
    self.client = client
    self.key = key

    let task = Task {
      print("queryobserver \(key) task start")
      
      for await state in await client.subscribe(for: key) {
        self.state = state
        print("queryobserver \(key) task update, status = \(self.state.status)")
      }
      
      print("queryobserver \(key) task exit")
    }

    cancellable = AnyCancellable { task.cancel() }
  }

  public func invalidate() {
    Task {
      await client.invalidate(key: key)
    }
  }

  public func wait() async -> Result<K.Result, Error> {
    for await update in await client.subscribe(for: key) {
      switch update.status {
      case let .success(value: value): return .success(value)
      case let .error(error: error): return .failure(error)
      default: continue
      }
    }

    return .failure(ObserverError.canceled)
  }

  public func refetch() async -> Result<K.Result, Error> {
    await client.invalidate(key: key)
    return await wait()
  }

  func cancel() {
    cancellable?.cancel()
  }
}
