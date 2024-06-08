import Combine
import NotificationCenter

public struct QueryUpdate<Key> where Key: QueryKey {
  public let key: Key
  public let update: StatusUpdate
}

var queryDidChange = Notification.Name("queryDidChange")

@available(iOS 16.0, *)
public struct QueryConfig<Key> where Key: QueryKey {
  public var run: ((Key) async throws -> Any?)?
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
class QueryState<Key>: NSDiscardableContent where Key: QueryKey {
  public var config: QueryConfig<Key>
  public var fetchStatus: FetchStatus = .idle
  public var dataStatus: DataStatus = .idle
  public var lastRequestTime: ContinuousClock.Instant?
  public var retryCount: UInt = 0

  var forceRefetch: Bool = false
  var userCount: Int = 0
  var task: Task<Void, Never>? = nil
  var discarded: Bool = false

  init(config: QueryConfig<Key>) {
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

      fetchStatus = .idle
      dataStatus = .idle
      discarded = true
    }
  }

  func isContentDiscarded() -> Bool {
    discarded
  }
}

public enum FetchStatus {
  case idle, fetching
}

public enum DataStatus {
  case idle, pending, success(Any?), error(Error)

  public var isIdle: Bool {
    if case .idle = self {
      true
    } else {
      false
    }
  }

  public var isPending: Bool {
    if case .pending = self {
      true
    } else {
      false
    }
  }

  public var isSuccess: Bool {
    if case .success = self {
      true
    } else {
      false
    }
  }

  public var isError: Bool {
    if case .error = self {
      true
    } else {
      false
    }
  }
}

public enum TypedDataStatus<Value> {
  case idle, pending, success(Value), error(Error)

  public var isIdle: Bool {
    if case .idle = self {
      true
    } else {
      false
    }
  }

  public var isPending: Bool {
    if case .pending = self {
      true
    } else {
      false
    }
  }

  public var isSuccess: Bool {
    if case .success = self {
      true
    } else {
      false
    }
  }

  public var isError: Bool {
    if case .error = self {
      true
    } else {
      false
    }
  }
}

public enum QueryError: Error {
  case typeMismatch
}

extension DataStatus {
  func typed<Value>() -> TypedDataStatus<Value> {
    switch self {
    case let .error(err): .error(err)
    case .idle: .idle
    case .pending: .pending
    case let .success(value):
      if let value = value as? Value {
        .success(value)
      } else {
        .error(QueryError.typeMismatch)
      }
    }
  }
}

@MainActor
@available(iOS 16.0, *)
public class Query<Key> where Key: QueryKey {
  let key: Key
  public let client: QueryClient<Key>

  init(key: Key, client: QueryClient<Key>) {
    self.key = key
    self.client = client
  }

  var state: QueryState<Key> {
    client.queryState(for: key)
  }

  public var dataStatus: DataStatus {
    state.dataStatus
  }

  public var fetchStatus: FetchStatus {
    state.fetchStatus
  }

  public var data: Any? {
    get {
      switch state.dataStatus {
      case let .success(value):
        value
      default:
        nil
      }
    }
    set {
      if let value = newValue {
        state.dataStatus = .success(value)
      } else {
        state.dataStatus = .idle
      }

      client.notifyQueryReset(for: key)
    }
  }

  public var error: Error? {
    get {
      switch state.dataStatus {
      case let .error(err):
        err
      default:
        nil
      }
    }
    set {
      if let err = newValue {
        state.dataStatus = .error(err)
      } else {
        state.dataStatus = .idle
      }

      client.notifyQueryReset(for: key)
    }
  }

  public var dataPublisher: AnyPublisher<Any?, Never> {
    client.queryUpdates()
      .filter { $0.key == self.key }
      .map { _ in self.data }
      .handleEvents(
        receiveSubscription: { [unowned self] _ in client.addQueryUser(for: key) },
        receiveCompletion: { [unowned self] _ in client.removeQueryUser(for: key) },
        receiveCancel: { self.client.removeQueryUser(for: self.key) }
      )
      .eraseToAnyPublisher()
  }

  public var statusPublisher: AnyPublisher<DataStatus, Never> {
    client.queryUpdates()
      .filter { $0.key == self.key }
      .map { _ in self.dataStatus }
      .handleEvents(
        receiveSubscription: { [unowned self] _ in client.addQueryUser(for: key) },
        receiveCompletion: { [unowned self] _ in client.removeQueryUser(for: key) },
        receiveCancel: { self.client.removeQueryUser(for: self.key) }
      )
      .eraseToAnyPublisher()
  }

  public func typed<Value>() -> TypedQuery<Key, Value> {
    TypedQuery<Key, Value>(inner: self)
  }

  public func refetch() {
    state.forceRefetch = true
    client.notifyQueryReset(for: key)
  }

  public func refetchAsync() async {
    refetch()

    for await update in client.queryUpdatesAsync() {
      if update.key != key { continue }
      switch dataStatus {
      case .idle, .pending: continue
      default: break
      }

      break
    }
  }
}

@MainActor
@available(iOS 16.0, *)
public class TypedQuery<Key, Value> where Key: QueryKey {
  let inner: Query<Key>

  init(inner: Query<Key>) {
    self.inner = inner
  }

  var key: Key { inner.key }
  var client: QueryClient<Key> { inner.client }

  var state: QueryState<Key> {
    inner.state
  }

  public var dataStatus: TypedDataStatus<Value> {
    inner.dataStatus.typed()
  }

  public var fetchStatus: FetchStatus {
    inner.fetchStatus
  }

  public var data: Value? {
    get {
      switch dataStatus {
      case let .success(value):
        value
      default:
        nil
      }
    }
    set {
      if let value = newValue {
        state.dataStatus = .success(value)
      } else {
        state.dataStatus = .idle
      }

      client.notifyQueryReset(for: key)
    }
  }

  public var error: Error? {
    get { inner.error }
    set {
      // notifyQueryReset is raised by setting inner.error
      inner.error = newValue
    }
  }

  public var dataPublisher: AnyPublisher<Value?, Never> {
    inner.dataPublisher.map { value in value as? Value }.eraseToAnyPublisher()
  }

  public var statusPublisher: AnyPublisher<TypedDataStatus<Value>, Never> {
    inner.statusPublisher.map { status in status.typed() }.eraseToAnyPublisher()
  }

  public func observed() -> ObservedQuery<Key, Value> {
    ObservedQuery(inner: self)
  }

  public func refetch() {
    inner.refetch()
  }

  public func refetchAsync() async {
    await inner.refetchAsync()
  }
}

@MainActor
@available(iOS 16.0, *)
public class ObservedQuery<Key, Value>: ObservableObject where Key: QueryKey {
  let inner: TypedQuery<Key, Value>
  var subscription: AnyCancellable

  init(inner: TypedQuery<Key, Value>) {
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

  public var dataStatus: TypedDataStatus<Value> { inner.dataStatus }

  public var fetchStatus: FetchStatus {
    inner.fetchStatus
  }

  var state: QueryState<Key> {
    inner.state
  }

  public var data: Value? {
    get {
      switch dataStatus {
      case let .success(value):
        value
      default:
        nil
      }
    }

    set {
      if let value = newValue {
        state.dataStatus = .success(value)
      } else {
        state.dataStatus = .idle
      }

      client.notifyQueryReset(for: key)
    }
  }

  public var error: Error? {
    get { inner.error }
    set { inner.error = newValue }
  }

  public var dataPublisher: AnyPublisher<Value?, Never> { inner.dataPublisher }

  public var statusPublisher: AnyPublisher<TypedDataStatus<Value>, Never> { inner.statusPublisher }

  public func refetch() {
    inner.refetch()
  }

  public func refetchAsync() async {
    await inner.refetchAsync()
  }
}
