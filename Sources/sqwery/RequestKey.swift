protocol RequestKey: Hashable {
  associatedtype Result

  var type: RequestType { get }

  var resultLifetime: Duration { get }

  var retryDelay: Duration { get }
  var retryLimit: Int { get }

  func run() async throws -> Result
}

enum RequestType {
  case query
  case mutation
}
