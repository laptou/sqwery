import Alamofire
import Combine
import Foundation
import os
import Semaphore

public actor QueryClient {
  public static let shared = QueryClient()

  private let subject = PassthroughSubject<(requestKey: AnyHashable, requestState: Any), Never>()
  private var tasks: [AnyHashable: Task<Void, Never>] = [:]
  private var semaphores: [AnyHashable: AsyncSemaphore] = [:]
  private var subscriberCounts: [AnyHashable: Int] = [:]
  private let cache = RequestCache()

  private func ensureSemaphore(for key: some QueryKey) -> AsyncSemaphore {
    if semaphores[key] == nil {
      semaphores[key] = AsyncSemaphore(value: 1)
    }

    return semaphores[key]!
  }

  private func withLock<T>(for key: some QueryKey, fn: () async -> T) async -> T {
    let semaphore = ensureSemaphore(for: key)
    await semaphore.wait()
    defer { semaphore.signal() }

    return await fn()
  }

  public func subscribe<K: QueryKey>(for key: K) -> AsyncStream<RequestState<K.Result, Void>> {
    subscriberCounts[key, default: 0] += 1

    if tasks[key] == nil {
      tasks[key] = Task { [weak self] in
        await self?.fetchQuery(for: key)
      }
    }

    return subject
      .filter { $0.requestKey == AnyHashable(key) }
      .compactMap { $0.requestState as? RequestState<K.Result, Void> }
      .handleEvents(receiveCancel: { [weak self] in
        Task { [weak self] in
          await self?.unsubscribe(for: key)
        }
      })
      .stream
  }

  public func getState<K: QueryKey>(for key: K) async -> RequestState<K.Result, Void> {
    await cache.getOrCreate(for: key)
  }

  private func unsubscribe(for key: some QueryKey) async {
    subscriberCounts[key, default: 1] -= 1
    if subscriberCounts[key] == 0 {
      await cancel(for: key)
    }
  }

  private func cancel(for key: some QueryKey) async {
    let logger = logger(for: key)
    logger.trace("cancelling query")

    tasks[key]?.cancel()

    // acquire lock on task to ensure that it actually cancelled
    let semaphore = ensureSemaphore(for: key)
    await semaphore.wait()
    semaphore.signal()

    tasks.removeValue(forKey: key)

    logger.info("cancelled query")
  }

  private func logger(for key: some QueryKey) -> Logger {
    Logger(
      subsystem: "sqwery",
      category: "query \(String(describing: key))"
    )
  }

  private func fetchQuery<K: QueryKey>(for key: K) async {
    let semaphore = ensureSemaphore(for: key)
    do {
      try await semaphore.waitUnlessCancelled()
    } catch {
      return
    }

    let logger = logger(for: key)
    logger.debug("fetch loop starting")

    defer {
      semaphore.signal()
      logger.info("fetch loop exiting")
    }

    while !Task.isCancelled {
      logger.trace("fetch loop iter")

      var state: RequestState<K.Result, Void> = await cache.getOrCreate(for: key)

      switch state.queryStatus {
      case .success, .error:
        // if we already have a success or error value, then don't replace it with pending
        // instead we just update the fetch status
        break
      case .idle, .pending:
        state.queryStatus = .pending(progress: ())
      }

      await cache.set(for: key, state: state)
      subject.send((key, state))

      do {
        if !state.invalidated {
          if let finishedFetching = state.finishedFetching {
            let timeSinceFetch = Duration.seconds(Date.now.timeIntervalSince(finishedFetching))
            logger.trace("refetch detected, result is \(timeSinceFetch) old")
            if timeSinceFetch < key.resultLifetime {
              logger.trace("refetch detected, result is too fresh, delaying")
              try? await Task.sleep(for: key.resultLifetime - timeSinceFetch)
              continue
            }
          }
        } else {
          logger.trace("invalidate detected, forcing refetch")

          state.invalidated = false
          state.retryCount = 0
        }

        state.beganFetching = Date.now
        state.fetchStatus = .fetching
        await cache.set(for: key, state: state)
        subject.send((key, state))

        while true {
          do {
            logger.trace("running fetch function")
            let result = try await key.run(client: self)
            logger.trace("completed fetch function")

            state.retryCount = 0
            state.finishedFetching = Date.now
            state.queryStatus = .success(value: result)
            state.fetchStatus = .idle
            await cache.set(for: key, state: state)
            subject.send((key, state))

            await key.onSuccess(client: self, result: result)
            break
          } catch {
            // if we errored but the task was cancelled (presumably BECAUSE the task was cancelled), it doesn't count
            if Task.isCancelled { break }

            state.retryCount += 1

            if state.retryCount >= key.retryLimit {
              logger.error("fetch failed, exceeded retry limit: \(error)")
              throw error
            }

            logger.warning("fetch failed, retrying: \(error)")

            await cache.set(for: key, state: state)
            subject.send((key, state))

            try? await Task.sleep(for: key.retryDelay)
          }
        }

        try? await Task.sleep(for: key.resultLifetime)
      } catch is CancellationError {
        logger.info("fetch cancelled, exiting loop")
        break
      } catch {
        // if we errored but the task was cancelled (presumably BECAUSE the task was cancelled), it doesn't count
        if Task.isCancelled { break }

        state.finishedFetching = Date.now
        state.queryStatus = .error(error: error)
        state.fetchStatus = .idle
        await cache.set(for: key, state: state)
        subject.send((key, state))

        await key.onError(client: self, error: error)
        break
      }
    }
  }

  private func restartQuery(for key: some QueryKey) async {
    let logger = logger(for: key)
    logger.info("restarting query")

    await cancel(for: key)
    tasks[key] = Task { [weak self] in
      await self?.fetchQuery(for: key)
    }
  }

  public func invalidate<K: QueryKey>(key: K) async {
    var state: RequestState<K.Result, Void> = await cache.getOrCreate(for: key)
    state.invalidated = true
    await cache.set(for: key, state: state)

    if subscriberCounts[key, default: 0] > 0 {
      await restartQuery(for: key)
    }
  }

  public func invalidateWhere(_ predicate: (any QueryKey) -> Bool) async {
    await withDiscardingTaskGroup {
      for (key, _) in tasks {
        let queryKey = key.base as! any QueryKey
        if !predicate(queryKey) { continue }

        var state = await cache.getUntyped(for: key)
        state?.invalidated = true

        if subscriberCounts[key, default: 0] > 0 {
          $0.addTask { await self.restartQuery(for: queryKey) }
        }
      }
    }
  }

  public func invalidateAll() async {
    await withDiscardingTaskGroup {
      for (key, _) in tasks {
        let queryKey = key.base as! any QueryKey

        var state = await cache.getUntyped(for: key)
        state?.invalidated = true

        if subscriberCounts[key, default: 0] > 0 {
          $0.addTask { await self.restartQuery(for: queryKey) }
        }
      }
    }
  }

  public func setData<K: QueryKey>(for key: K, data: K.Result) async {
    let logger = logger(for: key)
    logger.info("set data for query, cancelling")
    await cancel(for: key)

    var state: RequestState<K.Result, Void> = await cache.getOrCreate(for: key)
    state.queryStatus = .success(value: data)
    state.fetchStatus = .idle
    state.finishedFetching = Date.now
    state.beganFetching = Date.now
    state.retryCount = 0
    await cache.set(for: key, state: state)

    subject.send((key, state))
    await invalidate(key: key)
    print("set query data for \(key)")
  }
}
