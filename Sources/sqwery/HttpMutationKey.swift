import Alamofire
import Foundation

public protocol HttpMutationKey: MutationKey where Result: Decodable {
  associatedtype Url: URLConvertible
  associatedtype Result = Alamofire.Empty

  var url: Url { get }
  var method: HTTPMethod { get }
  var headers: [String: String] { get }
  func body(for parameter: Parameter) throws -> Data?
  
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
  var headers: [String: String] { [:] }
  
  var validResponseCodes: Set<Int>? { nil }
  var validContentTypes: Set<String>? { nil }

  var emptyResponseCodes: Set<Int> { [204, 205] }
  var emptyRequestMethods: Set<HTTPMethod> { [.head] }
  
  var responseDataDecoder: any DataDecoder { JSONDecoder() }

  func run(parameter: Parameter) async throws -> Result {
    var urlRequest = try URLRequest(url: url.asURL())
    urlRequest.method = method
    urlRequest.httpBody = try body(for: parameter)
    urlRequest.headers = HTTPHeaders(headers)

    var dataRequest = AF.request(urlRequest)
    
    if let validResponseCodes = validResponseCodes {
      dataRequest = dataRequest.validate(statusCode: validResponseCodes)
    }
    
    if let validContentTypes = validContentTypes {
      dataRequest = dataRequest.validate(contentType: validContentTypes)
    }
    
    if validResponseCodes == nil && validContentTypes == nil {
      dataRequest = dataRequest.validate()
    }
    
    let task = dataRequest.serializingDecodable(
      Result.self, decoder: responseDataDecoder, emptyResponseCodes: emptyResponseCodes, emptyRequestMethods: emptyRequestMethods)
    
    let value = try await task.value
    return value
  }
}

/// Convenience protocol for HTTP queries with JSON bodies, provides a default implementation of `run()` which uses Alamofire to send the request
/// and a default implementation of `body` which serializes `bodyData` to JSON.
public protocol HttpJsonMutationKey: HttpMutationKey {
  associatedtype Body: Encodable
  
  /// The data of the request body, which will be serialized as JSON.
  func bodyData(for parameter: Parameter) throws -> Body
}

public extension HttpJsonMutationKey {
  func body(for parameter: Parameter) throws -> Data? {
    try JSONEncoder().encode(bodyData(for: parameter))
  }
}
