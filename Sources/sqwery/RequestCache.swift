import Foundation

actor RequestCache {
  private let cache = NSCache<CacheKey, CacheValue>()

  func get<Result, Progress>(for key: AnyHashable) -> RequestState<Result, Progress> {
    let cacheKey = CacheKey(key)
    if let cacheValue = cache.object(forKey: cacheKey) {
      if let state = cacheValue.value as? RequestState<Result, Progress> {
        return state
      } else {
        // this should never happen
        #if DEBUG
          fatalError("could not cast request state type")
        #else
          return RequestState<Result, Progress>()
        #endif
      }
    } else {
      let state = RequestState<Result, Progress>()
      set(for: key, state: state)
      return state
    }
  }

  func set(for key: AnyHashable, state: RequestState<some Any, some Any>) {
    cache.setObject(CacheValue(state), forKey: CacheKey(key))
  }

  func clear(for key: AnyHashable) {
    let cacheKey = CacheKey(key)
    cache.removeObject(forKey: cacheKey)
  }

  func clearAll() {
    cache.removeAllObjects()
  }

  // Helper classes for NSCache
  private class CacheKey: NSObject {
    let key: AnyHashable

    init(_ key: AnyHashable) {
      self.key = key
      super.init()
    }

    override var hash: Int {
      key.hashValue
    }

    override func isEqual(_ object: Any?) -> Bool {
      guard let other = object as? CacheKey else { return false }
      return key == other.key
    }
  }

  private class CacheValue: NSObject {
    let value: Any

    init(_ value: some Any) {
      self.value = value
      super.init()
    }
  }
}
