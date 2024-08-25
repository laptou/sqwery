public protocol MutationKey: Hashable {
  associatedtype Result = ()
  associatedtype Parameter = ()
  associatedtype Progress = ()

  var retryDelay: Duration { get }
  var retryLimit: Int { get }

  func run(client: MutationClient, parameter: Parameter, onProgress: @escaping (Progress) -> Void) async throws -> Result

  func onSuccess(client: MutationClient, parameter: Parameter, result: Result) async
  func onError(client: MutationClient, parameter: Parameter, error: Error) async
}

public extension MutationKey {
  func onSuccess(client: MutationClient, parameter: Parameter, result: Result) async {}
  func onError(client: MutationClient, parameter: Parameter, error: Error) async {}
}
