import Combine
import Foundation
import SwiftUI

@propertyWrapper
public struct Query<K: QueryKey>: DynamicProperty {
  @ObservedObject private var observer: QueryObserver<K>

  init(_ key: K, queryClient: QueryClient) {
    _observer = ObservedObject(wrappedValue: QueryObserver(client: queryClient, key: key))
  }

  public var wrappedValue: RequestStatus<K.Result> {
    observer.status
  }

  public var projectedValue: QueryObserver<K> {
    observer
  }
}
