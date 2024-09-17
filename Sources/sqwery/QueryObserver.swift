import Combine
import Foundation
import os

@MainActor
public class QueryObserver<K: QueryKey>: ObservableObject {
  @Published public private(set) var state: RequestState<K.Result, Void>
  public var queryStatus: QueryStatus<K.Result, Void> { state.queryStatus }
  public var fetchStatus: FetchStatus { state.fetchStatus }

  private var cancellable: AnyCancellable?
  private let client: QueryClient
  public var key: K {
    didSet {
      if oldValue != key {
        // resubscribe after key is changed
        subscribe()
      }
    }
  }

  init(client: QueryClient, key: K) {
    self.client = client
    self.key = key
    state = RequestState()
    
    self.subscribe()
  }
  
  func subscribe() {
    let key = self.key
    
    if let cancellable {
      cancellable.cancel()
    }
    
    let task = Task { @MainActor in
      let logger = Logger(
        subsystem: "sqwery",
        category: "query \(String(describing: key))"
      )
      
      self.state = await client.getState(for: key)
      logger.debug("queryobserver \(String(describing: key)) task start, status = \(String(describing: self.state.queryStatus))")
      
      for await state in await client.subscribe(for: key) {
        self.state = state
        logger.trace("queryobserver \(String(describing: key)) task update, status = \(String(describing: self.state.queryStatus))")
      }
      
      logger.debug("queryobserver \(String(describing: key)) task exit")
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
      switch update.queryStatus {
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
