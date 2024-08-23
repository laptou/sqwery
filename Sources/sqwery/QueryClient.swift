import Foundation
import Combine
import Alamofire

actor QueryClient {
  private let subject = PassthroughSubject<(requestKey: AnyHashable, requestState: Any), Never>()
  private var tasks: [AnyHashable: Task<Void, Never>] = [:]
  private var subscriberCounts: [AnyHashable: Int] = [:]
  private let cache = RequestCache()
  
  func startFetching<K: RequestKey>(for key: K) -> AnyPublisher<RequestState<K.Result>, Never> {
    if key.type == .query {
      subscriberCounts[key, default: 0] += 1
      
      if tasks[key] == nil {
        tasks[key] = Task { [weak self] in
          await self?.fetchLoop(for: key)
        }
      }
    } else {
      fatalError("unimplemented")
    }
    
    return subject
      .filter { $0.requestKey == AnyHashable(key) }
      .compactMap { $0.requestState as? RequestState<K.Result> }
      .handleEvents(receiveCancel: { [weak self] in
        Task { [weak self] in
          await self?.decrementSubscriberCount(for: key)
        }
      })
      .eraseToAnyPublisher()
  }
  
  private func decrementSubscriberCount(for key: AnyHashable) {
    subscriberCounts[key, default: 1] -= 1
    if subscriberCounts[key] == 0 {
      stopFetching(for: key)
    }
  }
  
  private func stopFetching(for key: AnyHashable) {
    tasks[key]?.cancel()
    tasks.removeValue(forKey: key)
    subscriberCounts.removeValue(forKey: key)
  }
  
  private func fetchLoop<K: RequestKey>(for key: K) async {
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
        var result: K.Result? = nil
        
        while true {
          do {
            result = try await key.run()
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
  
  func invalidate<K: RequestKey>(key: K) {
    Task {
      await cache.clear(for: key)
      if subscriberCounts[key, default: 0] > 0 {
        tasks[key]?.cancel()
        tasks[key] = Task { [weak self] in
          await self?.fetchLoop(for: key)
        }
      }
    }
  }
  
  func invalidateWhere(_ predicate: (any RequestKey) -> Bool) {
    Task {
      await cache.clearAll()
      for (key, _) in tasks {
        if !predicate(key.base as! any RequestKey) { continue }
        
        if subscriberCounts[key, default: 0] > 0 {
          tasks[key]?.cancel()
          if let requestKey = key.base as? any RequestKey {
            tasks[key] = Task { [weak self] in
              await self?.fetchLoop(for: requestKey)
            }
          }
        }
      }
    }
  }
  
  func invalidateAll() {
    Task {
      await cache.clearAll()
      for (key, _) in tasks {
        if subscriberCounts[key, default: 0] > 0 {
          tasks[key]?.cancel()
          if let requestKey = key.base as? any RequestKey {
            tasks[key] = Task { [weak self] in
              await self?.fetchLoop(for: requestKey)
            }
          }
        }
      }
    }
  }
}

