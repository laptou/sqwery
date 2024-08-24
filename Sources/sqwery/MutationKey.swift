public protocol MutationKey: Hashable {
  associatedtype Result = ()
  associatedtype Parameter = ()
  associatedtype Progress = ()

  var retryDelay: Duration { get }
  var retryLimit: Int { get }

  func run(parameter: Parameter, onProgress: @escaping (Progress) -> Void) async throws -> Result
}
