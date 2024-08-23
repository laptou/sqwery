public protocol QueryKey: Hashable {
  associatedtype Result

  var resultLifetime: Duration { get }

  var retryDelay: Duration { get }
  var retryLimit: Int { get }

  func run() async throws -> Result
}
