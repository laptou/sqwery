import Foundation

actor RequestCache {
  private let cache = NSCache<CacheKey, CacheValue>()
  
  func get<Result>(for key: AnyHashable) -> RequestState<Result> {
    let cacheKey = CacheKey(key)
    if let cacheValue = cache.object(forKey: cacheKey) {
      if let state = cacheValue.value as? RequestState<Result> {
        return state
      } else {
#if DEBUG
        fatalError("could not cast request state type")
#endif
        // log a warning
      }
    } else {
      let state = RequestState<Result>()
      cache.setObject(CacheValue(state), forKey: CacheKey(key))
      return state
    }
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
    
    init<T>(_ value: T) {
      self.value = value
      super.init()
    }
  }
}
