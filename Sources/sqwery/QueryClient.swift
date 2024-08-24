import Alamofire
import Combine
import Foundation

public actor QueryClient {
  public static let shared = QueryClient()
  
  private let subject = PassthroughSubject<(requestKey: AnyHashable, requestState: Any), Never>()
  private var tasks: [AnyHashable: Task<Void, Never>] = [:]
  private var subscriberCounts: [AnyHashable: Int] = [:]
  private let cache = RequestCache()

  public func subscribe<K: QueryKey>(for key: K) -> AnyPublisher<RequestState<K.Result>, Never> {
    subscriberCounts[key, default: 0] += 1

    if tasks[key] == nil {
      tasks[key] = Task { [weak self] in
        await self?.fetchQuery(for: key)
      }
    }

    return subject
      .filter { $0.requestKey == AnyHashable(key) }
      .compactMap { $0.requestState as? RequestState<K.Result> }
      .handleEvents(receiveCancel: { [weak self] in
        Task { [weak self] in
          await self?.unsubscribe(for: key)
        }
      })
      .eraseToAnyPublisher()
  }

  private func unsubscribe(for key: AnyHashable) {
    subscriberCounts[key, default: 1] -= 1
    if subscriberCounts[key] == 0 {
      cancel(for: key)
    }
  }

  private func cancel(for key: AnyHashable) {
    tasks[key]?.cancel()
    tasks.removeValue(forKey: key)
    subscriberCounts.removeValue(forKey: key)
  }

  private func fetchQuery<K: QueryKey>(for key: K) async {
    while !Task.isCancelled {
      var state: RequestState<K.Result, ()> = await cache.get(for: key)
      state.status = .pending(progress: ())
      await cache.set(for: key, state: state)
      subject.send((key, state))

      do {
        if let finishedFetching = state.finishedFetching {
          let timeSinceFetch = Duration.seconds(Date.now.timeIntervalSince(finishedFetching))
          if timeSinceFetch < key.resultLifetime {
            try? await Task.sleep(for: key.resultLifetime - timeSinceFetch)
            continue
          }
        }

        state.beganFetching = Date.now
        await cache.set(for: key, state: state)
        subject.send((key, state))

        var attempt = 0
        var result: K.Result?

        while true {
          do {
            result = try await key.run()
            break
          } catch {
            state.retryCount += 1

            if state.retryCount >= key.retryLimit {
              throw error
            }
            
            await cache.set(for: key, state: state)
            subject.send((key, state))

            try? await Task.sleep(for: key.retryDelay)
          }
        }

        state.finishedFetching = Date.now
        state.status = .success(value: result!)
        await cache.set(for: key, state: state)
        subject.send((key, state))

        try? await Task.sleep(for: key.resultLifetime)
      } catch is CancellationError {
        break
      } catch {
        state.finishedFetching = Date.now
        state.status = .error(error: error)
        await cache.set(for: key, state: state)
        subject.send((key, state))
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
    var state: RequestState<K.Resultm ()> = await cache.get(for: key)
    state.status = .success(value: data)
    state.finishedFetching = Date.now
    state.beganFetching = Date.now
    state.retryCount = 0
    await cache.set(for: key, state: state)
  }
}
