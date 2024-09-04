import Alamofire
import Foundation

public protocol HttpMutationKey: MutationKey where Result: Decodable {
  associatedtype Url: URLConvertible
  associatedtype Result = Alamofire.Empty

  func url(for parameter: Parameter) async -> Url
  func method(for parameter: Parameter) async -> HTTPMethod
  func headers(for parameter: Parameter) async -> [String: String]
  func body(for parameter: Parameter) async throws -> Data?

  /// Response codes that are considered valid for this request. Return nil to accept all response codes in `200..299`
  var validResponseCodes: Set<Int>? { get }
  /// Content types that are considered valid for this request. Return nil to accept the content types that were specified in the `Accept` header.
  var validContentTypes: Set<String>? { get }

  /// Response codes that are allowed to come with empty responses. Defaults to `[204, 205]`.
  var emptyResponseCodes: Set<Int> { get }
  /// Request methods that are allowed to return empty responses. Defaults to `HEAD`.
  var emptyRequestMethods: Set<HTTPMethod> { get }

  /// Decoder that is used to deserialize the returned data into the `Result` type. Defaults to `JSONDecoder`.
  var responseDataDecoder: any DataDecoder { get }
}

public extension HttpMutationKey {
  func headers(for parameter: Parameter) async -> [String: String] {
    [:]
  }
  
  func body(for parameter: Parameter) async throws -> Data? {
    return nil
  }

  var validResponseCodes: Set<Int>? { nil }
  var validContentTypes: Set<String>? { nil }

  var emptyResponseCodes: Set<Int> { [204, 205] }
  var emptyRequestMethods: Set<HTTPMethod> { [.head] }

  var responseDataDecoder: any DataDecoder { JSONDecoder() }

  func run(client: MutationClient, parameter: Parameter, onProgress: @escaping (Progress) -> Void) async throws -> Result {
    var urlRequest = try await URLRequest(url: url(for: parameter).asURL())
    urlRequest.method = await method(for: parameter)
    urlRequest.httpBody = try await body(for: parameter)
    urlRequest.headers = await HTTPHeaders(headers(for: parameter))

    var dataRequest = AF.request(urlRequest)

    if let validResponseCodes {
      dataRequest = dataRequest.validate(statusCode: validResponseCodes)
    }

    if let validContentTypes {
      dataRequest = dataRequest.validate(contentType: validContentTypes)
    }

    if validResponseCodes == nil, validContentTypes == nil {
      dataRequest = dataRequest.validate()
    }

    let task = dataRequest.serializingDecodable(
      Result.self, decoder: responseDataDecoder, emptyResponseCodes: emptyResponseCodes, emptyRequestMethods: emptyRequestMethods
    )

    let value = try await task.value
    return value
  }
}

/// Convenience protocol for HTTP queries with JSON bodies, provides a default implementation of `run()` which uses Alamofire to send the request
/// and a default implementation of `body` which serializes `bodyData` to JSON.
public protocol HttpJsonMutationKey: HttpMutationKey {
  associatedtype Body: Encodable = Alamofire.Empty

  /// The data of the request body, which will be serialized as JSON.
  func bodyData(for parameter: Parameter) async throws -> Body
}

public extension HttpJsonMutationKey {
  func body(for parameter: Parameter) async throws -> Data? {
    try await JSONEncoder().encode(bodyData(for: parameter))
  }
}

public extension HttpJsonMutationKey where Self.Body == Self.Parameter {
  func bodyData(for parameter: Parameter) async throws -> Body {
    parameter
  }
}
