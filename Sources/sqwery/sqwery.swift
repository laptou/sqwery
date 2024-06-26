import Cache
import Combine
import Foundation
import os

public protocol QueryKey: Hashable & Equatable {}

public protocol QueryKeyPredicate: Equatable {
  associatedtype Key: QueryKey

  func matches(key: Key) -> Bool
  func conflicts(other: Self) -> Bool
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

  public func conflicts(other _: Self) -> Bool {
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

// NSCache can only use keys that implement NSObject
final class WrappedKey<K>: NSObject where K: Hashable & Equatable {
  let key: K

  init(_ key: K) { self.key = key }

  override var hash: Int { key.hashValue }

  override func isEqual(_ object: Any?) -> Bool {
    guard let value = object as? WrappedKey else {
      return false
    }

    return value.key == key
  }
}

@MainActor
@available(iOS 16.0, *)
public class QueryClient<Key> where Key: QueryKey {
  /// Enables or disables automatically refreshing queries. Useful to disable this for previews.
  public var autoRefresh: Bool = true

  private let queryCache: NSCache<WrappedKey<Key>, QueryState<Key>>
  private let mutationCache: NSCache<WrappedKey<MutationId<Key>>, MutationState<Key>>
  private var queryConfigurers: [(matches: (Key) -> Bool, equals: (any QueryKeyPredicate) -> Bool, configurer: QueryConfigurer<Key>)] = []
  private var mutationConfigurers: [(matches: (Key) -> Bool, equals: (any QueryKeyPredicate) -> Bool, configurer: MutationConfigurer<Key>)] = []

  private var notifications: NotificationCenter = .init()
  private var queryUsers: [Key: Int] = [:]
  private var queryTasks: [Key: Task<Void, Never>] = [:]
  private var mutationKeys: Set<MutationId<Key>> = []
  private var mutationTasks: [MutationId<Key>: Task<Void, Never>] = [:]
  private var mutationNextId: [Key: Int] = [:]

  public var defaultQueryConfig: QueryConfig<Key> = QueryConfig()
  public var defaultMutationConfig: MutationConfig<Key> = MutationConfig()

  public init() {
    queryCache = NSCache()
    queryCache.evictsObjectsWithDiscardedContent = true
    mutationCache = NSCache()
    mutationCache.evictsObjectsWithDiscardedContent = true
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
      let state = queryState(for: key)
      print("running query \(String(describing: key)) due to non-zero users")

      // we went from zero observers for this query to not-zero, start a task
      let task = Task { @MainActor [weak self] in
        guard let self else { return }
        await runQuery(key: key)

        // when the task exits (due to cancellation, for example) deregister it
        queryTasks.removeValue(forKey: key)
        notifyQueryReset(for: key)
      }

      // store the task in the query state so that it gets cancelled when NSCache evicts it
      state.task = task
      queryTasks[key] = task
    }
  }

  func removeQueryUser(for key: Key) {
    if let usersForKey = queryUsers[key] {
      queryUsers[key] = usersForKey - 1
    }

    if queryUsers[key] == nil || queryUsers[key]! <= 0 {
      // we went from not-zero observers to zero, cancel the task
      if let taskForKey = queryTasks[key] {
        print("canceling query \(String(describing: key)) due to zero users")
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

  private func waitForQueryUpdate(for key: Key) async {
    // no more retries available, wait until something changes
    var iter = notifications.notifications(named: queryDidChange)
      // Notification is not Sendable, so we map the iterator even though we're not using the objects
      .map { $0.object as! QueryUpdate }
      .filter {
        $0.key == key
      }
      .makeAsyncIterator()

    let _ = await iter.next()
  }

  func runQuery(key: Key) async {
    print("runQuery \(String(describing: key)) started")

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
            await waitForQueryUpdate(for: key)

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

        // if we have success and auto refresh is disabled, do nothing
        if !autoRefresh {
          await waitForQueryUpdate(for: key)
          continue
        }

        do {
          // in success state? sleep until stale time, or query update, then retry
          if !currentState.forceRefetch {
            if let lastRequestTime = currentState.lastRequestTime {
              let staleTime = lastRequestTime + currentState.config.lifetime
              let delay = staleTime - ContinuousClock.now
              logger.log(level: .debug, "query \(String(describing: key)) waiting to refresh for \(delay)")

              let interrupted = try await withThrowingTaskGroup(of: Bool.self) {
                group in

                group.addTask { try await Task.sleep(for: delay); return false }
                group.addTask { await self.waitForQueryUpdate(for: key); return true }

                let interrupted = try await group.next()
                group.cancelAll()
                return interrupted
              }

              if interrupted == true { continue }

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

                try await withThrowingTaskGroup(of: Void.self) {
                  group in

                  group.addTask { try await Task.sleep(for: delay) }
                  group.addTask { await self.waitForQueryUpdate(for: key) }

                  try await group.next()
                  group.cancelAll()
                }
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
          await waitForQueryUpdate(for: key)
          continue
        }
      }

      queryCache.setObject(currentState, forKey: WrappedKey(key))
    }

    print("runQuery \(String(describing: key)) stopped")
  }

  func runMutation(for id: MutationId<Key>, param: Any? = nil) async {
    let currentState = mutationState(for: id)
    currentState.dataStatus = .pending

    while currentState.retryCount < currentState.config.retryLimit, !Task.isCancelled {
      do {
        let runner = currentState.config.run

        if let runner {
          currentState.dataStatus = .pending
          // prevent NSCache from evicting our mutation and cancelling the task while it's running
          currentState.beginContentAccess()
          logger.log(level: .debug, "mutation \(String(describing: id)) idle -> pending")
          notifications.post(name: mutationDidChange, object: MutationUpdate(mutationId: id, update: .began))

          let result = try await Task.detached { try await runner(id.key, param) }.value
          currentState.endContentAccess()
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

  public func queryUpdatesAsync() -> AsyncMapSequence<NotificationCenter.Notifications, QueryUpdate<Key>> {
    notifications.notifications(named: queryDidChange).map { $0.object as! QueryUpdate }
  }

  public func mutationUpdates() -> AnyPublisher<MutationUpdate<Key>, Never> {
    notifications.publisher(for: mutationDidChange).map { $0.object as! MutationUpdate }.eraseToAnyPublisher()
  }

  public func mutationUpdatesAsync() -> AsyncMapSequence<NotificationCenter.Notifications, MutationUpdate<Key>> {
    notifications.notifications(named: mutationDidChange).map { $0.object as! MutationUpdate }
  }

  public func configureQueries<P>(for predicate: P, configurer: @escaping (inout QueryConfig<Key>) -> Void) where P: QueryKeyPredicate, P.Key == Key {
    queryConfigurers.removeAll(where: { _, equals, _ in equals(predicate) })
    queryConfigurers.append(
      ({ predicate.matches(key: $0) }, { predicate == $0 as? P }, configurer)
    )

    invalidateQueries(for: predicate)
  }

  public func configureMutations<P>(for predicate: P, configurer: @escaping (inout MutationConfig<Key>) -> Void) where P: QueryKeyPredicate, P.Key == Key {
    mutationConfigurers.removeAll(where: { _, equals, _ in equals(predicate) })
    mutationConfigurers.append(
      ({ predicate.matches(key: $0) }, { predicate == $0 as? P }, configurer)
    )

    invalidateMutations(for: predicate)
  }

  public func invalidateQueries<P>(for predicate: P, remove: Bool = false) where P: QueryKeyPredicate, P.Key == Key {
    for (key, users) in queryUsers {
      if predicate.matches(key: key) {
        // cancel the query task
        if let task = queryTasks[key] {
          task.cancel()
        }

        if remove {
          // delete the entire cached query state
          queryCache.removeObject(forKey: WrappedKey(key))
        } else if let queryState = queryCache.object(forKey: WrappedKey(key)) {
          // reset the query's configuration and force a refresh
          queryState.config = buildQueryConfig(for: key)
          queryState.forceRefetch = true
        }

        print("invalidated query \(String(describing: key))")

        // start/restart the query task
        if let users = queryUsers[key], users > 0 {
          let state = queryState(for: key)

          let task = Task.detached { @MainActor [weak self] in
            guard let self else { return }
            await runQuery(key: key)

            queryTasks.removeValue(forKey: key)
            notifyQueryReset(for: key)
          }

          state.task = task
          queryTasks[key] = task
        }

        notifyQueryReset(for: key)
      }
    }
  }

  public func invalidateMutations<P>(for predicate: P, remove _: Bool = false) where P: QueryKeyPredicate, P.Key == Key {
    for id in mutationKeys {
      if predicate.matches(key: id.key) {
        mutationCache.removeObject(forKey: WrappedKey(id))

        // cancel the mutation task
        if let task = mutationTasks[id] {
          task.cancel()
        }

        notifications.post(name: mutationDidChange, object: MutationUpdate(mutationId: id, update: .reset))
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

  func queryState(for key: Key) -> QueryState<Key> {
    switch queryCache.object(forKey: WrappedKey(key)) {
    case .none:
      let newState = QueryState<Key>(config: buildQueryConfig(for: key))
      queryCache.setObject(newState, forKey: WrappedKey(key))
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

  func mutationState(for id: MutationId<Key>) -> MutationState<Key> {
    switch try? mutationCache.object(forKey: WrappedKey(id)) {
    case .none:
      let newState = MutationState<Key>(config: buildMutationConfig(for: id.key))
      mutationCache.setObject(newState, forKey: WrappedKey(id))
      return newState
    case let .some(state):
      return state
    }
  }
}
