import Combine
import Foundation
import SwiftUI

@propertyWrapper
public struct Query<K: QueryKey>: DynamicProperty {
  @StateObject private var observer: QueryObserver<K>

  public init(_ key: K, queryClient: QueryClient) {
    _observer = StateObject(wrappedValue: QueryObserver(client: queryClient, key: key))
  }

  public init(_ key: K) {
    _observer = StateObject(wrappedValue: QueryObserver(client: QueryClient.shared, key: key))
  }

  public var projectedValue: QueryStatus<K.Result, Void> {
    observer.queryStatus
  }

  public var wrappedValue: QueryObserver<K> {
    observer
  }
}
