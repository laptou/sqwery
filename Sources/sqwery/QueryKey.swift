/// Uniquely identifiers a query and provides information about how this query should run.
public protocol QueryKey: Hashable {
  associatedtype Result

  var resultLifetime: Duration { get }

  var retryDelay: Duration { get }
  var retryLimit: Int { get }

  func run(client: QueryClient) async throws -> Result

  func onSuccess(client: QueryClient, result: Result) async
  func onError(client: QueryClient, error: Error) async
}

public extension QueryKey {
  func onSuccess(client _: QueryClient, result _: Result) async {}
  func onError(client _: QueryClient, error _: Error) async {}
}

extension Optional: QueryKey where Wrapped: QueryKey {
  public var resultLifetime: Duration {
    if let self {
      return self.resultLifetime
    }
    
    return Duration.seconds(1_000_000_000)
  }
  
  public var retryDelay: Duration {
    if let self {
      return self.retryDelay
    }
    
    return Duration.zero
  }
  
  public var retryLimit: Int {
    if let self {
      return self.retryLimit
    }
    
    return 0
  }
  
  public func run(client: QueryClient) async throws -> Wrapped.Result? {
    if let self {
      return try await self.run(client: client)
    }
    
    return nil
  }
  
  public typealias Result = Wrapped.Result?
}
