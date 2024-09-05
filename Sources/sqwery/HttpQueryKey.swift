import Alamofire
import Foundation

/// Convenience protocol for HTTP queries, provides a default implementation of `run()` which uses Alamofire to send the request.
/// Any responses will be deserialized by Alamofire, which expects JSON by default.
public protocol HttpQueryKey: QueryKey where Result: Decodable {
  associatedtype Url: URLConvertible
  associatedtype Result = Alamofire.Empty

  var url: Url { get async }
  var method: HTTPMethod { get }
  var headers: [String: String] { get async }
  var body: Data? { get throws }

  /// Response codes that are considered valid for this request. Return nil to accept all response codes in `200..299`. Defaults to nil.
  var validResponseCodes: Set<Int>? { get }
  /// Content types that are considered valid for this request. Return nil to accept the content types that were specified in the `Accept` header. Defaults to nil.
  var validContentTypes: Set<String>? { get }

  /// Response codes that are allowed to come with empty responses. Defaults to `[204, 205]`.
  var emptyResponseCodes: Set<Int> { get }
  /// Request methods that are allowed to return empty responses. Defaults to `HEAD`.
  var emptyRequestMethods: Set<HTTPMethod> { get }

  /// Decoder that is used to deserialize the returned data into the `Result` type. Defaults to `JSONDecoder`.
  var responseDataDecoder: any DataDecoder { get }
}

public extension HttpQueryKey {
  var headers: [String: String] { [:] }
  var body: Data? { nil }

  var validResponseCodes: Set<Int>? { nil }
  var validContentTypes: Set<String>? { nil }

  var emptyResponseCodes: Set<Int> { [204, 205] }
  var emptyRequestMethods: Set<HTTPMethod> { [.head] }

  var responseDataDecoder: any DataDecoder { JSONDecoder() }

  func run(client _: QueryClient) async throws -> Result {
    var urlRequest = try await URLRequest(url: url.asURL())
    urlRequest.method = method
    urlRequest.httpBody = try body
    urlRequest.headers = await HTTPHeaders(headers)

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
