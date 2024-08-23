import Combine
import NotificationCenter

public struct MutationId<Key>: Hashable & Equatable where Key: QueryKey {
  public var key: Key
  public var id: Int
}

public struct MutationUpdate<Key> where Key: QueryKey {
  public let mutationId: MutationId<Key>
  public let update: StatusUpdate
}

var mutationDidChange = Notification.Name("mutationDidChange")

@available(iOS 16.0, *)
public struct MutationConfig<Key> where Key: QueryKey {
  public var run: (@MainActor (Key, Any?) async throws -> Any?)?
  /// Time until the data fetched by this query is considered stale
  public var lifetime: Duration
  /// Time in between retries when the query errors
  public var retryDelay: Duration
  /// Maximum number of automatic retries to attempt
  public var retryLimit: UInt

  init() {
    run = nil
    lifetime = Duration.seconds(600)
    retryDelay = Duration.seconds(10)
    retryLimit = 3
  }
}

@MainActor
@available(iOS 16.0, *)
class MutationState<Key>: NSDiscardableContent where Key: QueryKey {
  public var config: MutationConfig<Key>
  public var dataStatus: DataStatus = .idle
  public var lastRequestTime: ContinuousClock.Instant?
  public var retryCount: UInt = 0
  public var parameters: Any?

  var userCount: Int = 0
  var task: Task<Void, Never>? = nil
  var discarded: Bool = false

  init(config: MutationConfig<Key>) {
    self.config = config
  }

  func beginContentAccess() -> Bool {
    if discarded { return false }

    userCount += 1
    return true
  }

  func endContentAccess() {
    userCount -= 1
  }

  func discardContentIfPossible() {
    if userCount == 0 {
      task?.cancel()

      dataStatus = .idle
      discarded = true
    }
  }

  func isContentDiscarded() -> Bool {
    discarded
  }
}

@MainActor
@available(iOS 16.0, *)
public class Mutation<Key> where Key: QueryKey {
  // mutations can be run several times, and the query
  // client keeps track of the state of each run with the id
  var currentId: Int = -1

  let key: Key
  public let client: QueryClient<Key>

  init(key: Key, client: QueryClient<Key>) {
    self.key = key
    self.client = client
  }

  public var id: MutationId<Key> {
    MutationId(key: key, id: currentId)
  }

  var state: MutationState<Key> {
    client.mutationState(for: id)
  }

  public var status: DataStatus {
    state.dataStatus
  }

  public var data: Any? {
    switch state.dataStatus {
    case let .success(value):
      value
    default:
      nil
    }
  }

  public var error: Error? {
    switch state.dataStatus {
    case let .error(err):
      err
    default:
      nil
    }
  }

  public var dataPublisher: AnyPublisher<Any?, Never> {
    client.mutationUpdates()
      .filter { $0.mutationId == self.id }
      .map { _ in self.data }
      .eraseToAnyPublisher()
  }

  public var statusPublisher: AnyPublisher<DataStatus, Never> {
    client.mutationUpdates()
      .filter { $0.mutationId == self.id }
      .map { _ in self.status }
      .eraseToAnyPublisher()
  }

  public func typed<Value, Param>() -> TypedMutation<Key, Value, Param> {
    TypedMutation<Key, Value, Param>(inner: self)
  }

  public func run(_ param: Any? = nil) {
    currentId = client.getNextMutationId(for: key)
    client.startMutation(for: id, param: param)
  }

  public func runAsync(_ param: Any? = nil) async -> Any? {
    run(param)

    for await update in client.mutationUpdatesAsync() {
      if update.mutationId != id { continue }
      switch status {
      case .idle, .pending: continue
      case let .success(value): return value
      default: break
      }

      break
    }
    
    return nil
  }
}

@MainActor
@available(iOS 16.0, *)
public class TypedMutation<Key, Value, Param> where Key: QueryKey {
  let inner: Mutation<Key>

  init(inner: Mutation<Key>) {
    self.inner = inner
  }

  var key: Key { inner.key }
  var client: QueryClient<Key> { inner.client }

  var state: MutationState<Key> {
    inner.state
  }

  public var status: TypedDataStatus<Value> {
    inner.status.typed()
  }

  public var data: Value? {
    switch status {
    case let .success(value):
      value
    default:
      nil
    }
  }

  public var error: Error? {
    inner.error
  }

  public var dataPublisher: AnyPublisher<Value?, Never> {
    inner.dataPublisher.map { value in value as? Value }.eraseToAnyPublisher()
  }

  public var statusPublisher: AnyPublisher<TypedDataStatus<Value>, Never> {
    inner.statusPublisher.map { status in status.typed() }.eraseToAnyPublisher()
  }

  public func observed() -> ObservedMutation<Key, Value, Param> {
    ObservedMutation(inner: self)
  }

  public func run(_ param: Param) {
    inner.run(param)
  }

  public func runAsync(_ param: Param) async -> Value? {
    return await inner.runAsync(param) as? Value
  }
}

@MainActor
@available(iOS 16.0, *)
public class ObservedMutation<Key, Value, Param>: ObservableObject where Key: QueryKey {
  let inner: TypedMutation<Key, Value, Param>
  var subscription: AnyCancellable

  init(inner: TypedMutation<Key, Value, Param>) {
    self.inner = inner
    // we can't create the sink without initializing all the properties of self first
    subscription = AnyCancellable {}
    subscription = self.inner.statusPublisher.sink(
      receiveValue: {
        [weak self] _ in
        self?.objectWillChange.send()
      }
    )
  }

  var key: Key { inner.key }
  var client: QueryClient<Key> { inner.client }

  public var status: TypedDataStatus<Value> { inner.status }

  var state: MutationState<Key> { inner.state }

  public var data: Value? { inner.data }

  public var error: Error? { inner.error }

  public var dataPublisher: AnyPublisher<Value?, Never> { inner.dataPublisher }

  public var statusPublisher: AnyPublisher<TypedDataStatus<Value>, Never> { inner.statusPublisher }

  public func run(_ param: Param)  {
    return inner.run(param)
  }

  public func runAsync(_ param: Param) async -> Value? {
    return await inner.runAsync(param)
  }
}
