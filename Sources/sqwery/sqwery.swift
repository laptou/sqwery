import Cache
import Combine
import Foundation

public protocol QueryKey: Hashable & Equatable {}

public protocol QueryPredicate {
  associatedtype Key: QueryKey
  
  func matches(key: Key) -> Bool
}

extension QueryPredicate {
  static func all() -> AllQueries<Key> {
    return AllQueries()
  }
}

public struct AllQueries<K>: QueryPredicate where K: QueryKey {
  public typealias Key = K
  
  public func matches(key: Key) -> Bool {
    return true
  }
}

@available(iOS 16.0, *)
public typealias QueryConfigurer<Key> = (inout QueryConfig<Key>) -> Void

enum QueryUpdate {
  case expired, succeeded(Any), errored(Error), reset
}

@MainActor
@available(iOS 16.0, *)
public class QueryClient<Key> where Key: QueryKey {
  private let cache: MemoryStorage<Key, QueryState<Key>>
  private var configurers: [((Key) -> Bool, QueryConfigurer<Key>)] = []
  var users: [Key: Int] = [:]
  var tasks: [Key: Task<Void, Never>] = [:]
  let updates: PassthroughSubject<(Key, QueryUpdate), Never> = PassthroughSubject()

  public init() {
    cache = MemoryStorage(config: MemoryConfig())
  }

  func buildQueryConfig(for key: Key) -> QueryConfig<Key> {
    var config = QueryConfig<Key>()

    for (predicate, configurer) in configurers {
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
      tasks[key] = Task { [weak self] in
        guard let self else { return }

        while true {
          var currentState = await MainActor.run { self.state(for: key) }

          switch currentState.status {
          case .idle:
            do {
              // idle and we have subscribers? kick off our query
              let runner = currentState.config.run
              currentState.status = .pending

              if let runner {
                let result = try await runner(key)
                currentState.status = .success(result)
              }
            } catch is CancellationError {
              currentState.status = .idle
              break
            } catch {
              currentState.status = .error(error)
            }

            currentState.lastRequestTime = ContinuousClock.now
          case .success:
            do {
              // in success state? sleep until stale time, then retry
              if let lastRequestTime = currentState.lastRequestTime {
                let staleTime = lastRequestTime + currentState.config.lifetime
                let delay = ContinuousClock.now - staleTime
                try await Task.sleep(for: delay)
              }

              // in success and refreshing? kick off our query,
              // but don't change the state until we get results back
              let runner = currentState.config.run

              if let runner {
                let result = try await runner(key)
                currentState.status = .success(result)
              }
            } catch is CancellationError {
              break
            } catch {
              currentState.status = .error(error)
            }

            currentState.lastRequestTime = ContinuousClock.now
          case .error:
            if currentState.retryCount < currentState.config.retryLimit {
              do {
                // in error state? sleep until retry time, then retry
                if let lastRequestTime = currentState.lastRequestTime {
                  let staleTime = lastRequestTime + currentState.config.retryDelay
                  let delay = ContinuousClock.now - staleTime
                  try await Task.sleep(for: delay)
                }

                let runner = currentState.config.run

                if let runner {
                  currentState.status = .pending
                  let result = try await runner(key)
                  currentState.status = .success(result)
                }
              } catch is CancellationError {
                break
              } catch {
                currentState.retryCount += 1
                currentState.status = .error(error)
              }

              currentState.lastRequestTime = ContinuousClock.now
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

  public func config<P>(for predicate: P, configurer: @escaping QueryConfigurer<Key>) where P: QueryPredicate, P.Key == Key {
    configurers.append(
      ({ predicate.matches(key: $0) }, configurer)
    )
  }
  
  public func clear<P>(for predicate: P) where P: QueryPredicate, P.Key == Key {
    for key in cache.allKeys {
      if predicate.matches(key: key) {
        cache.removeObject(forKey: key)
      }
    }
  }

  public func query(for key: Key) -> Query<Key> {
    Query<Key>(key: key, client: self, config: buildQueryConfig(for: key))
  }

  public func typedQuery<Value>(for key: Key) -> TypedQuery<Key, Value> {
    query(for: key).typed()
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
  public let run: ((Key) async throws -> Any)?
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
  public var status: QueryStatus = .idle
  public var lastRequestTime: ContinuousClock.Instant?
  public var retryCount: UInt = 0

  init(config: QueryConfig<Key>) {
    self.config = config
  }
}

public enum QueryStatus {
  case idle, pending, success(Any), error(Error)
}

public enum TypedQueryStatus<Value> {
  case idle, pending, success(Value), error(Error)
}

public enum QueryError: Error {
  case typeMismatch
}

extension QueryStatus {
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

  var state: QueryState<Key> {
    client.state(for: key)
  }

  var status: QueryStatus {
    state.status
  }

  var data: Any? {
    get {
      switch state.status {
      case let .success(value):
        value
      default:
        nil
      }
    }
    set {
      if let value = newValue {
        state.status = .success(value)
      } else {
        state.status = .idle
      }
    }
  }

  var dataPublisher: AnyPublisher<Any?, Never> {
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

  var statusPublisher: AnyPublisher<QueryStatus, Never> {
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

  func typed<Value>() -> TypedQuery<Key, Value> {
    TypedQuery<Key, Value>(inner: self)
  }
}

@MainActor
@available(iOS 16.0, *)
public class TypedQuery<Key, Value> where Key: QueryKey {
  let inner: Query<Key>

  init(inner: Query<Key>) {
    self.inner = inner
  }

  var state: QueryState<Key> {
    inner.state
  }

  var status: TypedQueryStatus<Value> {
    inner.status.typed()
  }

  var data: Any? {
    switch state.status {
    case let .success(value):
      value
    default:
      nil
    }
  }

  var dataPublisher: AnyPublisher<Value?, Never> {
    inner.dataPublisher.map { value in value as? Value }.eraseToAnyPublisher()
  }

  var statusPublisher: AnyPublisher<TypedQueryStatus<Value>, Never> {
    inner.statusPublisher.map { status in status.typed() }.eraseToAnyPublisher()
  }
}
