import Alamofire
import Combine
import Foundation

public actor QueryClient {
  private let subject = PassthroughSubject<(requestKey: AnyHashable, requestState: Any), Never>()
  private var tasks: [AnyHashable: Task<Void, Never>] = [:]
  private var subscriberCounts: [AnyHashable: Int] = [:]
  private let cache = RequestCache()

  func subscribe<K: QueryKey>(for key: K) -> AnyPublisher<RequestState<K.Result>, Never> {
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
      let state: RequestState<K.Result> = await cache.get(for: key)

      do {
        if let finishedFetching = state.finishedFetching {
          let timeSinceFetch = Duration.seconds(Date.now.timeIntervalSince(finishedFetching))
          if timeSinceFetch < key.resultLifetime {
            try? await Task.sleep(for: key.resultLifetime - timeSinceFetch)
            continue
          }
        }

        state.beganFetching = Date.now
        subject.send((key, state))

        var attempt = 0
        var result: K.Result?

        while true {
          do {
            result = try await key.run()
            break
          } catch {
            attempt += 1

            if attempt >= key.retryLimit {
              throw error
            }

            try? await Task.sleep(for: key.retryDelay)
          }
        }

        state.finishedFetching = Date.now
        state.status = .success(value: result!)
        subject.send((key, state))

        try? await Task.sleep(for: key.resultLifetime)
      } catch is CancellationError {
        break
      } catch {
        state.finishedFetching = Date.now
        state.status = .error(error: error)
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

  func invalidate(key: some QueryKey) async {
    await cache.clear(for: key)
    if subscriberCounts[key, default: 0] > 0 {
      restartQuery(for: key)
    }
  }

  func invalidateWhere(_ predicate: (any QueryKey) -> Bool) async {
    for (key, _) in tasks {
      let queryKey = key.base as! any QueryKey
      if !predicate(queryKey) { continue }

      await cache.clear(for: key)

      if subscriberCounts[key, default: 0] > 0 {
        restartQuery(for: queryKey)
      }
    }
  }

  func invalidateAll() async {
    await cache.clearAll()
    for (key, _) in tasks {
      let queryKey = key.base as! any QueryKey

      if subscriberCounts[key, default: 0] > 0 {
        restartQuery(for: queryKey)
      }
    }
  }
}
