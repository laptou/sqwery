import Combine
import SwiftUI

@propertyWrapper
public struct Mutation<K: MutationKey>: DynamicProperty {
  @StateObject private var observer: MutationObserver<K>

  public init(_ key: K, mutationClient: MutationClient) {
    _observer = StateObject(wrappedValue: MutationObserver(client: mutationClient, key: key))
  }
  
  public init(_ key: K) {
    _observer = StateObject(wrappedValue: MutationObserver(client: MutationClient.shared, key: key))
  }

  public var wrappedValue: RequestStatus<K.Result, K.Progress> {
    observer.status
  }

  public var projectedValue: MutationObserver<K> {
    observer
  }
}
