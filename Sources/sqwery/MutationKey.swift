public protocol MutationKey: Hashable {
  associatedtype Result = ()
  associatedtype Parameter = ()

  var retryDelay: Duration { get }
  var retryLimit: Int { get }

  func run(parameter: Parameter) async throws -> Result
}
