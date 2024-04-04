import Cache
import Combine
import Foundation
import os

public protocol QueryKey: Hashable & Equatable {}

public protocol QueryKeyPredicate: Equatable {
  associatedtype Key: QueryKey

  func matches(key: Key) -> Bool
  func contains(other: Self) -> Bool
}

public extension QueryKeyPredicate {
  static func all() -> AllQueries<Key> {
    AllQueries()
  }
}

public struct AllQueries<K>: QueryKeyPredicate, Equatable where K: QueryKey {
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
public typealias QueryConfigurer<Key: QueryKey> = (inout QueryConfig<Key>) -> Void

@available(iOS 16.0, *)
public typealias MutationConfigurer<Key: QueryKey> = (inout MutationConfig<Key>) -> Void

public enum StatusUpdate {
  case expired, began, succeeded(Any?), errored(Error), reset
}

@available(iOS 14.0, *)
var logger = Logger(subsystem: "me.abiodun.sqwery", category: "sqwery")

@MainActor
@available(iOS 16.0, *)
public class QueryClient<Key> where Key: QueryKey {
  private let queryCache: MemoryStorage<Key, QueryState<Key>>
  private let mutationCache: MemoryStorage<MutationId<Key>, MutationState<Key>>
  private var queryConfigurers: [(matches: (Key) -> Bool, equals: (any QueryKeyPredicate) -> Bool, configurer: QueryConfigurer<Key>)] = []
  private var mutationConfigurers: [(matches: (Key) -> Bool, equals: (any QueryKeyPredicate) -> Bool, configurer: MutationConfigurer<Key>)] = []

  private var notifications: NotificationCenter = .init()
  private var queryUsers: [Key: Int] = [:]
  private var queryTasks: [Key: Task<Void, Never>] = [:]
  private var mutationTasks: [MutationId<Key>: Task<Void, Never>] = [:]
  private var mutationNextId: [Key: Int] = [:]

  public var defaultQueryConfig: QueryConfig<Key> = QueryConfig()
  public var defaultMutationConfig: MutationConfig<Key> = MutationConfig()

  public init() {
    queryCache = MemoryStorage(config: MemoryConfig())
    mutationCache = MemoryStorage(config: MemoryConfig())
  }

  func buildQueryConfig(for key: Key) -> QueryConfig<Key> {
    var config = defaultQueryConfig

    for (predicate, _, configurer) in queryConfigurers {
      if predicate(key) {
        configurer(&config)
      }
    }

    return config
  }

  func buildMutationConfig(for key: Key) -> MutationConfig<Key> {
    var config = defaultMutationConfig

    for (predicate, _, configurer) in mutationConfigurers {
      if predicate(key) {
        configurer(&config)
      }
    }

    return config
  }

  func addQueryUser(for key: Key) {
    if let usersForKey = queryUsers[key] {
      queryUsers[key] = usersForKey + 1
    } else {
      queryUsers[key] = 1
    }

    if queryUsers[key]! > 0, !queryTasks.keys.contains(key) {
      // we went from zero observers for this query to not-zero, start a task
      queryTasks[key] = Task { @MainActor [weak self] in
        guard let self else { return }
        await runQuery(key: key)
      }
    }
  }

  func removeQueryUser(for key: Key) {
    if let usersForKey = queryUsers[key] {
      queryUsers[key] = usersForKey - 1
    }

    if queryUsers[key] == nil || queryUsers[key]! <= 0 {
      // we went from not-zero observers to zero, cancel the task
      if let taskForKey = queryTasks[key] {
        taskForKey.cancel()
        queryTasks.removeValue(forKey: key)
      }
    }
  }

  func startMutation(for id: MutationId<Key>, param: Any? = nil) {
    mutationTasks[id] = Task { @MainActor [weak self] in
      guard let self else { return }
      await runMutation(for: id, param: param)
    }
  }

  func runQuery(key: Key) async {
    while !Task.isCancelled {
      let currentState = queryState(for: key)

      switch currentState.dataStatus {
      case .idle, .pending:
        // if we enter the loop in the pending state, treat it the same as idle b/c it means that
        // the previous request got cancelled while waiting for a runner

        do {
          // idle and we have subscribers? kick off our query
          let runner = currentState.config.run
          currentState.dataStatus = .pending
          notifications.post(name: queryDidChange, object: QueryUpdate(key: key, update: .began))
          logger.log(level: .debug, "query \(String(describing: key)) idle -> pending")

          if let runner {
            currentState.forceRefetch = false
            currentState.fetchStatus = .fetching
            notifications.post(name: queryDidChange, object: QueryUpdate(key: key, update: .began))
            let result = try await Task.detached { try await runner(key) }.value
            currentState.dataStatus = .success(result)
            logger.log(level: .debug, "query \(String(describing: key)) pending -> success")
            notifications.post(name: queryDidChange, object: QueryUpdate(key: key, update: .succeeded(result)))
          } else {
            logger.log(level: .debug, "query \(String(describing: key)) pending, cannot run because it does not have a runner")
            // if we don't have a runner, wait until someone modifies the state of
            // the query client, then check again
            var iter = notifications.notifications(named: queryDidChange)
              // Notification is not Sendable, so we map the iterator even though we're not using the objects
              .map { $0.object as! QueryUpdate }
              .filter { $0.key == key }
              .makeAsyncIterator()
            let _ = await iter.next()

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
          if !currentState.forceRefetch {
            if let lastRequestTime = currentState.lastRequestTime {
              let staleTime = lastRequestTime + currentState.config.lifetime
              let delay = staleTime - ContinuousClock.now
              logger.log(level: .debug, "query \(String(describing: key)) waiting to refresh for \(delay)")
              try await Task.sleep(for: delay)
              notifications.post(name: queryDidChange, object: QueryUpdate(key: key, update: .expired))
            }
          } else {
            logger.log(level: .debug, "query \(String(describing: key)) force refetch")
          }
          
          // in success and refreshing? kick off our query,
          // but don't change the state until we get results back
          let runner = currentState.config.run

          if let runner {
            currentState.forceRefetch = false
            currentState.fetchStatus = .fetching
            notifications.post(name: queryDidChange, object: QueryUpdate(key: key, update: .began))
            let result = try await Task.detached { try await runner(key) }.value
            currentState.dataStatus = .success(result)
            logger.log(level: .debug, "query \(String(describing: key)) success -> success (refetched)")
            notifications.post(name: queryDidChange, object: QueryUpdate(key: key, update: .succeeded(result)))
          } else {
            logger.log(level: .debug, "query \(String(describing: key)) success, cannot refresh because it does not have a runner")
          }
        } catch is CancellationError {
          logger.log(level: .debug, "query \(String(describing: key)) success -> success (refetch cancelled)")
          break
        } catch {
          currentState.dataStatus = .error(error)
          logger.log(level: .debug, "query \(String(describing: key)) success -> error (refetch failed) (\(error))")
          notifications.post(name: queryDidChange, object: QueryUpdate(key: key, update: .errored(error)))
        }

        currentState.fetchStatus = .idle
        currentState.lastRequestTime = ContinuousClock.now
      case .error:
        if currentState.forceRefetch || currentState.retryCount < currentState.config.retryLimit {
          do {
            if !currentState.forceRefetch {
              // in error state? sleep until retry time, then retry
              if let lastRequestTime = currentState.lastRequestTime {
                let staleTime = lastRequestTime + currentState.config.retryDelay
                let delay = staleTime - ContinuousClock.now
                logger.log(level: .debug, "query \(String(describing: key)) waiting to retry for \(delay)")
                try await Task.sleep(for: delay)
              }
            } else {
              logger.log(level: .debug, "query \(String(describing: key)) force refetch")
            }

            let runner = currentState.config.run

            if let runner {
              currentState.forceRefetch = false
              currentState.fetchStatus = .fetching
              notifications.post(name: queryDidChange, object: QueryUpdate(key: key, update: .began))
              let result = try await Task.detached { try await runner(key) }.value
              currentState.dataStatus = .success(result)
              logger.log(level: .debug, "query \(String(describing: key)) error -> success (retry \(currentState.retryCount))")
              notifications.post(name: queryDidChange, object: QueryUpdate(key: key, update: .succeeded(result)))
            } else {
              logger.log(level: .debug, "query \(String(describing: key)) error, cannot retry because it does not have a runner")
              // can't retry b/c we don't have a runner, wait for something to change
              var iter = notifications.notifications(named: queryDidChange)
                // Notification is not Sendable, so we map the iterator even though we're not using the objects
                .map { $0.object as! QueryUpdate }
                .filter { $0.key == key }
                .makeAsyncIterator()
              let _ = await iter.next()

              continue
            }
          } catch is CancellationError {
            currentState.dataStatus = .idle
            logger.log(level: .debug, "query \(String(describing: key)) error -> idle (retry \(currentState.retryCount) cancelled)")
            notifications.post(name: queryDidChange, object: QueryUpdate(key: key, update: .reset))
            break
          } catch {
            currentState.retryCount += 1
            currentState.dataStatus = .error(error)
            logger.log(level: .debug, "query \(String(describing: key)) error -> error (retry \(currentState.retryCount)) (\(error))")
            notifications.post(name: queryDidChange, object: QueryUpdate(key: key, update: .errored(error)))
          }

          currentState.fetchStatus = .idle
          currentState.lastRequestTime = ContinuousClock.now
        } else {
          // no more retries available, wait until something changes
          var iter = notifications.notifications(named: queryDidChange)
            // Notification is not Sendable, so we map the iterator even though we're not using the objects
            .map { $0.object as! QueryUpdate }
            .filter { $0.key == key }
            .makeAsyncIterator()
          let _ = await iter.next()

          continue
        }
      }

      queryCache.setObject(currentState, forKey: key)
    }
  }

  func runMutation(for id: MutationId<Key>, param: Any? = nil) async {
    let currentState = mutationState(for: id)
    currentState.dataStatus = .pending

    while currentState.retryCount < currentState.config.retryLimit, !Task.isCancelled {
      do {
        let runner = currentState.config.run

        if let runner {
          currentState.dataStatus = .pending
          logger.log(level: .debug, "mutation \(String(describing: id)) idle -> pending")
          notifications.post(name: mutationDidChange, object: MutationUpdate(mutationId: id, update: .began))
          
          let result = try await Task.detached { try await runner(id.key, param) }.value
          currentState.dataStatus = .success(result)
          
          logger.log(level: .debug, "mutation \(String(describing: id)) pending -> success")
          notifications.post(name: mutationDidChange, object: MutationUpdate(mutationId: id, update: .succeeded(result)))

          break
        } else {
          logger.log(level: .debug, "mutation \(String(describing: id)) pending, cannot run because it does not have a runner")
          // can't run b/c we don't have a runner, wait for something to change
          var iter = notifications.notifications(named: mutationDidChange)
            // Notification is not Sendable, so we map the iterator even though we're not using the objects
            // for some reason Swift refuses to allow the following
//            .map({ $0.object as! MutationUpdate<Key> })
//            .filter({ $0.mutationId === id })
            .map { _ in () }
            .makeAsyncIterator()
          let _ = await iter.next()

          continue
        }
      } catch is CancellationError {
        currentState.dataStatus = .idle
        logger.log(level: .debug, "mutation \(String(describing: id)) pending -> idle (cancelled)")
        notifications.post(name: mutationDidChange, object: MutationUpdate(mutationId: id, update: .reset))
        break
      } catch {
        currentState.retryCount += 1
        currentState.dataStatus = .error(error)
        logger.log(level: .debug, "mutation \(String(describing: id)) pending -> error (retry \(currentState.retryCount)) (\(error))")
        notifications.post(name: mutationDidChange, object: MutationUpdate(mutationId: id, update: .errored(error)))
      }
    }
  }

  func notifyQueryReset(for key: Key) {
    notifications.post(name: queryDidChange, object: QueryUpdate(key: key, update: .reset))
  }
  
  
  func getNextMutationId(for key: Key) -> Int {
    if let id = mutationNextId[key] {
      mutationNextId[key]! += 1
      return id
    } else {
      mutationNextId[key] = 1
      return 0
    }
  }

  public func queryUpdates() -> AnyPublisher<QueryUpdate<Key>, Never> {
    notifications.publisher(for: queryDidChange).map { $0.object as! QueryUpdate }.eraseToAnyPublisher()
  }

  public func mutationUpdates() -> AnyPublisher<MutationUpdate<Key>, Never> {
    notifications.publisher(for: mutationDidChange).map { $0.object as! MutationUpdate }.eraseToAnyPublisher()
  }

  public func configureQueries<P>(for predicate: P, configurer: @escaping (inout QueryConfig<Key>) -> Void) where P: QueryKeyPredicate, P.Key == Key {
    queryConfigurers.removeAll(where: { _, equals, _ in equals(predicate) })
    queryConfigurers.append(
      ({ predicate.matches(key: $0) }, { predicate == $0 as! P }, configurer)
    )

    invalidateQueries(for: predicate)
  }

  public func configureMutations<P>(for predicate: P, configurer: @escaping (inout MutationConfig<Key>) -> Void) where P: QueryKeyPredicate, P.Key == Key {
    mutationConfigurers.removeAll(where: { _, equals, _ in equals(predicate) })
    mutationConfigurers.append(
      ({ predicate.matches(key: $0) }, { predicate == $0 as! P }, configurer)
    )

    invalidateMutations(for: predicate)
  }

  public func invalidateQueries<P>(for predicate: P, remove: Bool = false) where P: QueryKeyPredicate, P.Key == Key {
    for key in queryCache.allKeys {
      if predicate.matches(key: key) {
        if remove {
          // delete the entire cached query state
          queryCache.removeObject(forKey: key)
        } else {
          if let query = try? queryCache.object(forKey: key) {
            // reset the query's configuration and force a refresh
            query.config = buildQueryConfig(for: key)
            query.forceRefetch = true
          }
        }

        notifyQueryReset(for: key)

        // cancel/restart the query task
        if let task = queryTasks[key] {
          task.cancel()
        }

        if let users = queryUsers[key], users > 0 {
          queryTasks[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            await runQuery(key: key)
          }
        }
      }
    }
  }

  public func invalidateMutations<P>(for predicate: P, remove _: Bool = false) where P: QueryKeyPredicate, P.Key == Key {
    for id in mutationCache.allKeys {
      if predicate.matches(key: id.key) {
        mutationCache.removeObject(forKey: id)
        notifications.post(name: mutationDidChange, object: MutationUpdate(mutationId: id, update: .reset))

        // cancel the mutation task
        if let task = mutationTasks[id] {
          task.cancel()
        }
      }
    }
  }

  public func query(for key: Key) -> Query<Key> {
    Query<Key>(key: key, client: self)
  }

  public func typedQuery<Value>(for key: Key) -> TypedQuery<Key, Value> {
    query(for: key).typed()
  }

  public func observedQuery<Value>(for key: Key) -> ObservedQuery<Key, Value> {
    typedQuery(for: key).observed()
  }

  public func queryState(for key: Key) -> QueryState<Key> {
    switch try? queryCache.object(forKey: key) {
    case .none:
      let newState = QueryState<Key>(config: buildQueryConfig(for: key))
      queryCache.setObject(newState, forKey: key)
      return newState
    case let .some(state):
      return state
    }
  }

  public func setQueryData(for key: Key, data: Any?) {
    let state = queryState(for: key)
    state.dataStatus = .success(data)
    state.lastRequestTime = ContinuousClock.now
    state.retryCount = 0
    notifyQueryReset(for: key)
  }

  public func mutation(for key: Key) -> Mutation<Key> {
    Mutation<Key>(key: key, client: self)
  }

  public func typedMutation<Value, Param>(for key: Key) -> TypedMutation<Key, Value, Param> {
    mutation(for: key).typed()
  }

  public func observedMutation<Value, Param>(for key: Key) -> ObservedMutation<Key, Value, Param> {
    typedMutation(for: key).observed()
  }

  public func mutationState(for id: MutationId<Key>) -> MutationState<Key> {
    switch try? mutationCache.object(forKey: id) {
    case .none:
      let newState = MutationState<Key>(config: buildMutationConfig(for: id.key))
      mutationCache.setObject(newState, forKey: id)
      return newState
    case let .some(state):
      return state
    }
  }

  public func mutationStates(for key: Key) -> [MutationState<Key>] {
    var states: [MutationState<Key>] = []

    for id in mutationCache.allKeys {
      if id.key == key {
        if let state = try? mutationCache.object(forKey: id) {
          states.append(state)
        }
      }
    }

    return states
  }
}
