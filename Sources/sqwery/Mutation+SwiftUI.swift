import Combine
import SwiftUI

@propertyWrapper
public struct Mutation<K: MutationKey>: DynamicProperty {
  @StateObject private var observer: MutationObserver<K>

  init(_ key: K, mutationClient: MutationClient) {
    _observer = StateObject(wrappedValue: MutationObserver(client: mutationClient, key: key))
  }

  var wrappedValue: RequestStatus<K.Result> {
    observer.state.status
  }

  var projectedValue: MutationObserver<K> {
    observer
  }
}
