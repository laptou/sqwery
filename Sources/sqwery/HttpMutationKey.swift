import Alamofire
import Foundation

public protocol HttpMutationKey: MutationKey where Result: Decodable {
  associatedtype Url: URLConvertible
  associatedtype Result = Alamofire.Empty

  var url: Url { get }
  var method: HTTPMethod { get }
  var headers: [String: String] { get }
  func body(for parameter: Parameter) throws -> Data?

  var emptyResponseCodes: Set<Int> { get }
  var emptyRequestMethods: Set<HTTPMethod> { get }
}

public extension HttpMutationKey {
  var headers: [String: String] { [:] }

  var emptyResponseCodes: Set<Int> { [204, 205] }
  var emptyRequestMethods: Set<HTTPMethod> { [.head] }

  func run(parameter: Parameter) async throws -> Result {
    var urlRequest = try URLRequest(url: url.asURL())
    urlRequest.method = method
    urlRequest.httpBody = try body(for: parameter)
    urlRequest.headers = HTTPHeaders(headers)

    let task = AF.request(urlRequest).serializingDecodable(Result.self, emptyResponseCodes: emptyResponseCodes, emptyRequestMethods: emptyRequestMethods)
    let value = try await task.value
    return value
  }
}

public protocol HttpJsonMutationKey: HttpMutationKey {
  associatedtype Body: Encodable

  func bodyData(for parameter: Parameter) throws -> Body
}

public extension HttpJsonMutationKey {
  func body(for parameter: Parameter) throws -> Data? {
    try JSONEncoder().encode(bodyData(for: parameter))
  }
}
