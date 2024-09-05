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
