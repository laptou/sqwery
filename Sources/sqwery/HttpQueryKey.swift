import Alamofire
import Foundation

public protocol HttpQueryKey: QueryKey where Result: Decodable {
  associatedtype Url: URLConvertible
  associatedtype Result = Alamofire.Empty

  var url: Url { get }
  var method: HTTPMethod { get }
  var headers: [String: String] { get }
  var body: Data? { get throws }

  var emptyResponseCodes: Set<Int> { get }
  var emptyRequestMethods: Set<HTTPMethod> { get }
}

public extension HttpQueryKey {
  var headers: [String: String] { [:] }
  var body: Data? { nil }

  var emptyResponseCodes: Set<Int> { [204, 205] }
  var emptyRequestMethods: Set<HTTPMethod> { [.head] }

  func run() async throws -> Result {
    var urlRequest = try URLRequest(url: url.asURL())
    urlRequest.method = method
    urlRequest.httpBody = try body
    urlRequest.headers = HTTPHeaders(headers)

    let task = AF.request(urlRequest).serializingDecodable(Result.self, emptyResponseCodes: emptyResponseCodes, emptyRequestMethods: emptyRequestMethods)
    let value = try await task.value
    return value
  }
}

public protocol HttpJsonQueryKey: HttpQueryKey {
  associatedtype Body: Encodable

  var bodyData: Body { get }
}

public extension HttpJsonQueryKey {
  var body: Data? { get throws { try JSONEncoder().encode(bodyData) } }
}
