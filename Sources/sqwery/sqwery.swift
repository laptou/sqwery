import Cache
import Combine
import Foundation
import os

public protocol QueryKey: Hashable & Equatable {}

public protocol QueryPredicate: Equatable {
  associatedtype Key: QueryKey

  func matches(key: Key) -> Bool
  func contains(other: Self) -> Bool
}

public extension QueryPredicate {
  static func all() -> AllQueries<Key> {
    AllQueries()
  }
}

public struct AllQueries<K>: QueryPredicate, Equatable where K: QueryKey {
  public typealias Key = K

  public func matches(key _: Key) -> Bool {
    true
  }

  public func contains(other _: Self) -> Bool {
    true
  }

  public init() {}
}

@available(iOS 16.0, *)
public typealias QueryConfigurer<Key> = (inout QueryConfig<Key>) -> Void

enum QueryUpdate {
  case expired, succeeded(Any), errored(Error), reset
}

var queryDidChange = Notification.Name("wait")

@available(iOS 14.0, *)
var logger = Logger(subsystem: "me.abiodun.sqwery", category: "sqwery")

@MainActor
@available(iOS 16.0, *)
public class QueryClient<Key> where Key: QueryKey {
  private let cache: MemoryStorage<Key, QueryState<Key>>
  private var configurers: [(matches: (Key) -> Bool, equals: (any QueryPredicate) -> Bool, configurer: QueryConfigurer<Key>)] = []
  var notifications: NotificationCenter = .init()
  var users: [Key: Int] = [:]
  var tasks: [Key: Task<Void, Never>] = [:]
  let updates: PassthroughSubject<(Key, QueryUpdate), Never> = PassthroughSubject()

  public init() {
    cache = MemoryStorage(config: MemoryConfig())
  }

  func buildQueryConfig(for key: Key) -> QueryConfig<Key> {
    var config = QueryConfig<Key>()

    for (predicate, _, configurer) in configurers {
      if predicate(key) {
        configurer(&config)
      }
    }

    return config
  }

  func addQueryUser(for key: Key) {
    if let usersForKey = users[key] {
      users[key] = usersForKey + 1
    } else {
      users[key] = 1
    }

    if users[key] == 1 {
      // we went from zero observers for this query to not-zero, start a task
      tasks[key] = Task { @MainActor [weak self] in
        guard let self else { return }

        while true {
          var currentState = state(for: key)

          switch currentState.dataStatus {
          case .idle:
            do {
              // idle and we have subscribers? kick off our query
              let runner = currentState.config.run
              currentState.dataStatus = .pending
              logger.log(level: .debug, "query \(String(describing: key)) idle -> pending")

              if let runner {
                currentState.fetchStatus = .fetching
                let result = try await Task.detached { try await runner(key) }.value
                currentState.dataStatus = .success(result)
                logger.log(level: .debug, "query \(String(describing: key)) pending -> success")
                updates.send((key, .succeeded(result)))
              } else {
                // if we don't have a runner, wait until someone modifies the state of
                // the query client, then check again
                await notifications.notifications(named: queryDidChange)
                  .makeAsyncIterator()
                  .next()

                continue
              }
            } catch is CancellationError {
              currentState.dataStatus = .idle
              logger.log(level: .debug, "query \(String(describing: key)) pending -> idle (cancelled)")
              break
            } catch {
              currentState.dataStatus = .error(error)
              logger.log(level: .info, "query \(String(describing: key)) pending -> error (\(error))")
            }

            currentState.fetchStatus = .idle
            currentState.lastRequestTime = ContinuousClock.now
          case .success:
            // if we've entered success state for any reason, clear retry count
            currentState.retryCount = 0

            do {
              // in success state? sleep until stale time, then retry
              if let lastRequestTime = currentState.lastRequestTime {
                let staleTime = lastRequestTime + currentState.config.lifetime
                let delay = staleTime - ContinuousClock.now
                logger.log(level: .debug, "query \(String(describing: key)) waiting to refresh for \(delay)")
                try await Task.sleep(for: delay)
                updates.send((key, .expired))
              }

              // in success and refreshing? kick off our query,
              // but don't change the state until we get results back
              let runner = currentState.config.run

              if let runner {
                currentState.fetchStatus = .fetching
                let result = try await Task.detached { try await runner(key) }.value
                currentState.dataStatus = .success(result)
                logger.log(level: .debug, "query \(String(describing: key)) success -> success (refetched)")
                updates.send((key, .succeeded(result)))
              }
            } catch is CancellationError {
              logger.log(level: .debug, "query \(String(describing: key)) success -> success (refetch cancelled)")
              break
            } catch {
              currentState.dataStatus = .error(error)
              logger.log(level: .debug, "query \(String(describing: key)) success -> error (refetch failed) (\(error))")
              updates.send((key, .errored(error)))
            }

            currentState.fetchStatus = .idle
            currentState.lastRequestTime = ContinuousClock.now
          case .error:
            if currentState.retryCount < currentState.config.retryLimit {
              do {
                // in error state? sleep until retry time, then retry
                if let lastRequestTime = currentState.lastRequestTime {
                  let staleTime = lastRequestTime + currentState.config.retryDelay
                  let delay = staleTime - ContinuousClock.now
                  logger.log(level: .debug, "query \(String(describing: key)) waiting to retry for \(delay)")
                  try await Task.sleep(for: delay)
                }

                let runner = currentState.config.run

                if let runner {
                  currentState.fetchStatus = .idle
                  let result = try await Task.detached { try await runner(key) }.value
                  currentState.dataStatus = .success(result)
                  logger.log(level: .debug, "query \(String(describing: key)) error -> success (retry \(currentState.retryCount))")
                  updates.send((key, .succeeded(result)))
                } else {
                  // can't retry b/c we don't have a runner, wait for something to change
                  await notifications.notifications(named: queryDidChange)
                    .makeAsyncIterator()
                    .next()

                  continue
                }
              } catch is CancellationError {
                currentState.dataStatus = .idle
                logger.log(level: .debug, "query \(String(describing: key)) error -> idle (retry \(currentState.retryCount) cancelled)")
                updates.send((key, .reset))
                break
              } catch {
                currentState.retryCount += 1
                currentState.dataStatus = .error(error)
                logger.log(level: .debug, "query \(String(describing: key)) error -> error (retry \(currentState.retryCount)) (\(error))")
                updates.send((key, .errored(error)))
              }

              currentState.fetchStatus = .idle
              currentState.lastRequestTime = ContinuousClock.now
            } else {
              // no more retries available, wait until something changes
              await notifications.notifications(named: queryDidChange)
                .makeAsyncIterator()
                .next()

              continue
            }
          case .pending:
            // we should never end up here lol
            fatalError("query task entered invalid state")
          }

          cache.setObject(currentState, forKey: key)
        }
      }
    }
  }

  func removeQueryUser(for key: Key) {
    if let usersForKey = users[key] {
      users[key] = usersForKey - 1
    }

    if users[key] == nil || users[key]! <= 0 {
      // we went from not-zero observers to zero, cancel the task
      if let taskForKey = tasks[key] {
        taskForKey.cancel()
        tasks.removeValue(forKey: key)
      }
    }
  }

  func notifyQueryReset(for key: Key) {
    notifications.post(name: queryDidChange, object: nil)
    updates.send((key, .reset))
  }

  public func config<P>(for predicate: P, configurer: @escaping (inout QueryConfig<Key>) -> Void) where P: QueryPredicate, P.Key == Key {
    configurers.removeAll(where: { _, equals, _ in equals(predicate) })
    configurers.append(
      ({ predicate.matches(key: $0) }, { predicate == $0 as! P }, configurer)
    )

    clear(for: predicate)
  }

  public func clear<P>(for predicate: P) where P: QueryPredicate, P.Key == Key {
    for key in cache.allKeys {
      if predicate.matches(key: key) {
        cache.removeObject(forKey: key)
        notifyQueryReset(for: key)
      }
    }
  }

  public func query(for key: Key) -> Query<Key> {
    Query<Key>(key: key, client: self, config: buildQueryConfig(for: key))
  }

  public func typedQuery<Value>(for key: Key) -> TypedQuery<Key, Value> {
    query(for: key).typed()
  }

  public func observedQuery<Value>(for key: Key) -> ObservedQuery<Key, Value> {
    typedQuery(for: key).observed()
  }

  public func state(for key: Key) -> QueryState<Key> {
    switch try? cache.object(forKey: key) {
    case .none:
      let newState = QueryState<Key>(config: buildQueryConfig(for: key))
      cache.setObject(newState, forKey: key)
      return newState
    case let .some(state):
      return state
    }
  }
}

@available(iOS 16.0, *)
public struct QueryConfig<Key> {
  public var run: ((Key) async throws -> Any)?
  /// Time until the data fetched by this query is considered stale
  public var lifetime: Duration
  /// Time in between retries when the query errors
  public var retryDelay: Duration
  /// Maximum number of automatic retries to attempt
  public var retryLimit: UInt

  init() {
    run = nil
    lifetime = Duration.seconds(30)
    retryDelay = Duration.seconds(10)
    retryLimit = 3
  }
}

@available(iOS 16.0, *)
public class QueryState<Key> {
  public var config: QueryConfig<Key>
  public var fetchStatus: QueryFetchStatus = .idle
  public var dataStatus: QueryDataStatus = .idle
  public var lastRequestTime: ContinuousClock.Instant?
  public var retryCount: UInt = 0
  public var forceRefetch: Bool = false

  init(config: QueryConfig<Key>) {
    self.config = config
  }
}

public enum QueryFetchStatus {
  case idle, fetching
}

public enum QueryDataStatus {
  case idle, pending, success(Any), error(Error)
}

public enum TypedQueryStatus<Value> {
  case idle, pending, success(Value), error(Error)
}

public enum QueryError: Error {
  case typeMismatch
}

extension QueryDataStatus {
  func typed<Value>() -> TypedQueryStatus<Value> {
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
  let config: QueryConfig<Key>
  public let client: QueryClient<Key>

  init(key: Key, client: QueryClient<Key>, config: QueryConfig<Key>) {
    self.key = key
    self.client = client
    self.config = config
  }

  public var state: QueryState<Key> {
    client.state(for: key)
  }

  public var status: QueryDataStatus {
    state.dataStatus
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
    client.updates
      .filter { key, _ in key == self.key }
      .map { _ in self.data }
      .handleEvents(
        receiveSubscription: { [unowned self] _ in client.addQueryUser(for: key) },
        receiveCompletion: { [unowned self] _ in client.removeQueryUser(for: key) },
        receiveCancel: { self.client.removeQueryUser(for: self.key) }
      )
      .eraseToAnyPublisher()
  }

  public var statusPublisher: AnyPublisher<QueryDataStatus, Never> {
    client.updates
      .filter { key, _ in key == self.key }
      .map { _ in self.status }
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

  public var state: QueryState<Key> {
    inner.state
  }

  public var status: TypedQueryStatus<Value> {
    inner.status.typed()
  }

  public var data: Value? {
    get {
      switch status {
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

  public var statusPublisher: AnyPublisher<TypedQueryStatus<Value>, Never> {
    inner.statusPublisher.map { status in status.typed() }.eraseToAnyPublisher()
  }

  public func observed() -> ObservedQuery<Key, Value> {
    ObservedQuery(inner: self)
  }

  public func refetch() {
    inner.refetch()
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

  deinit {
    Task {
      @MainActor in
      self.subscription.cancel()
    }
  }

  var key: Key { inner.key }
  var client: QueryClient<Key> { inner.client }

  public var status: TypedQueryStatus<Value> { inner.status }

  public var state: QueryState<Key> {
    inner.state
  }

  public var data: Value? {
    get {
      switch status {
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

  public var statusPublisher: AnyPublisher<TypedQueryStatus<Value>, Never> { inner.statusPublisher }

  public func refetch() {
    inner.refetch()
  }
}
