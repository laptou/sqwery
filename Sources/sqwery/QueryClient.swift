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
  
  private func ensureSemaphore<K: QueryKey>(for key: K) -> AsyncSemaphore {
    if semaphores[key] == nil {
      semaphores[key] = AsyncSemaphore(value: 1)
    }
    
    return semaphores[key]!
  }
  
  private func withLock<T, K: QueryKey>(for key: K, fn: () async -> T) async -> T {
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

  private func unsubscribe<K: QueryKey>(for key: K) async {
    subscriberCounts[key, default: 1] -= 1
    if subscriberCounts[key] == 0 {
      await cancel(for: key)
    }
  }

  private func cancel<K: QueryKey>(for key: K) async {
    tasks[key]?.cancel()
    
    // acquire lock on task to ensure that it actually cancelled
    let semaphore = ensureSemaphore(for: key)
    await semaphore.wait()
    semaphore.signal()
    
    tasks.removeValue(forKey: key)
    subscriberCounts.removeValue(forKey: key)
  }

  private func fetchQuery<K: QueryKey>(for key: K) async {
    let semaphore = ensureSemaphore(for: key)
    do {
      try await semaphore.waitUnlessCancelled()
    } catch {
      return
    }
    
    let logger = Logger(
      subsystem: "sqwery",
      category: "query \(String(describing: key))"
    )
    
    logger.debug("fetch loop starting")
    
    defer {
      semaphore.signal()
      logger.info("fetch loop exiting")
    }
    
    while !Task.isCancelled {
      logger.trace("fetch loop iter")
      
      var state: RequestState<K.Result, Void> = await cache.get(for: key)
      state.status = .pending(progress: ())
      await cache.set(for: key, state: state)
      subject.send((key, state))

      do {
        if let finishedFetching = state.finishedFetching {
          let timeSinceFetch = Duration.seconds(Date.now.timeIntervalSince(finishedFetching))
          logger.trace("refetch detected, result is \(timeSinceFetch) old")
          if timeSinceFetch < key.resultLifetime {
            logger.trace("refetch detected, result is too old, delaying")
            try? await Task.sleep(for: key.resultLifetime - timeSinceFetch)
            continue
          }
        }

        state.beganFetching = Date.now
        await cache.set(for: key, state: state)
        subject.send((key, state))

        state.retryCount = 0

        while true {
          do {
            logger.trace("running fetch function")
            let result = try await key.run(client: self)
            logger.trace("completed fetch function")

            state.finishedFetching = Date.now
            state.status = .success(value: result)
            await cache.set(for: key, state: state)
            subject.send((key, state))

            await key.onSuccess(client: self, result: result)
            break
          } catch {
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
        state.finishedFetching = Date.now
        state.status = .error(error: error)
        await cache.set(for: key, state: state)
        subject.send((key, state))

        await key.onError(client: self, error: error)
        break
      }
    }
  }

  private func restartQuery(for key: some QueryKey) {
    tasks[key]?.cancel()
    tasks[key] = Task { [weak self] in
      await self?.fetchQuery(for: key)
    }
  }

  public func invalidate(key: some QueryKey) async {
    await cache.clear(for: key)
    if subscriberCounts[key, default: 0] > 0 {
      restartQuery(for: key)
    }
  }

  public func invalidateWhere(_ predicate: (any QueryKey) -> Bool) async {
    for (key, _) in tasks {
      let queryKey = key.base as! any QueryKey
      if !predicate(queryKey) { continue }

      await cache.clear(for: key)

      if subscriberCounts[key, default: 0] > 0 {
        restartQuery(for: queryKey)
      }
    }
  }

  public func invalidateAll() async {
    await cache.clearAll()
    for (key, _) in tasks {
      let queryKey = key.base as! any QueryKey

      if subscriberCounts[key, default: 0] > 0 {
        restartQuery(for: queryKey)
      }
    }
  }

  public func setData<K: QueryKey>(for key: K, data: K.Result) async {
    await cancel(for: key)
    
    var state: RequestState<K.Result, Void> = await cache.get(for: key)
    state.status = .success(value: data)
    state.finishedFetching = Date.now
    state.beganFetching = Date.now
    state.retryCount = 0
    await cache.set(for: key, state: state)
    
    subject.send((key, state))
    await invalidate(key: key)
    print("set query data for \(key)")
  }
}
