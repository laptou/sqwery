@testable import sqwery
import XCTest

enum TestQueryKey: QueryKey {
  case First, Second
}

extension TestQueryKey: QueryKeyPredicate {
  func matches(key: TestQueryKey) -> Bool {
    key == self
  }

  func conflicts(other: TestQueryKey) -> Bool {
    other == self
  }

  typealias Key = Self
}

@available(iOS 16.0, *)
final class sqweryTests: XCTestCase {
  @MainActor
  func testSimpleQuery() async throws {
    let queryClient = QueryClient<TestQueryKey>()
    let expectation = expectation(description: "query First to run once")

    queryClient.configureQueries(for: TestQueryKey.First, configurer: {
      $0.run = {
        _ in
        expectation.fulfill()
        return "Query 1 Data"
      }
    })

    let query: TypedQuery<_, String> = queryClient.typedQuery(for: .First)
    XCTAssertEqual(query.data, nil)

    await query.refetchAsync()
    XCTAssertEqual(query.data, "Query 1 Data")

    await fulfillment(of: [expectation], timeout: 3)
  }

  @MainActor
  func testAutoRefresh() async throws {
    let queryClient = QueryClient<TestQueryKey>()
    let expectation = expectation(description: "query First to run twice")
    expectation.expectedFulfillmentCount = 2

    queryClient.configureQueries(for: TestQueryKey.First, configurer: {
      $0.lifetime = .milliseconds(500)
      $0.run = {
        _ in
        expectation.fulfill()
        return "Query 1 Data"
      }
    })

    let query: TypedQuery<_, String> = queryClient.typedQuery(for: .First)
    XCTAssertEqual(query.data, nil)

    await query.refetchAsync()
    XCTAssertEqual(query.data, "Query 1 Data")

    try! await Task.sleep(for: .milliseconds(750))

    await fulfillment(of: [expectation], timeout: 3)
  }

  @MainActor
  func testManualRefresh() async throws {
    let queryClient = QueryClient<TestQueryKey>()
    let expectation = expectation(description: "query First to run twice")
    expectation.expectedFulfillmentCount = 2
    expectation.assertForOverFulfill = true

    queryClient.configureQueries(for: TestQueryKey.First, configurer: {
      $0.lifetime = .milliseconds(50000)
      $0.run = {
        _ in
        expectation.fulfill()
        return "Query 1 Data"
      }
    })

    let query: TypedQuery<_, String> = queryClient.typedQuery(for: .First)
    XCTAssertEqual(query.data, nil)

    await query.refetchAsync()
    XCTAssertEqual(query.data, "Query 1 Data")

    try! await Task.sleep(for: .milliseconds(1000))

    await query.refetchAsync()
    XCTAssertEqual(query.data, "Query 1 Data")

    await fulfillment(of: [expectation], timeout: 3)
  }
}
