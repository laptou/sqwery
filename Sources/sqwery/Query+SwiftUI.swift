import Combine
import Foundation
import SwiftUI

@propertyWrapper
public struct Query<K: QueryKey>: DynamicProperty {
  @ObservedObject private var observer: QueryObserver<K>

  init(_ key: K, queryClient: QueryClient) {
    _observer = ObservedObject(wrappedValue: QueryObserver(client: queryClient, key: key))
  }

  var wrappedValue: RequestStatus<K.Result> {
    observer.status
  }

  var projectedValue: QueryObserver<K> {
    observer
  }
}
