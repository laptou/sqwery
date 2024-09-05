// https://forums.swift.org/t/how-to-use-combine-publisher-with-swift-concurrency-publisher-values-could-miss-events/67193/9

@preconcurrency import Combine
import Foundation

public extension Publisher where Failure == Never {
  var stream: AsyncStream<Output> {
    AsyncStream { continuation in
      let cancellable = self.sink { _ in
        continuation.finish()
      } receiveValue: { value in
        continuation.yield(value)
      }
      continuation.onTermination = { _ in
        cancellable.cancel()
      }
    }
  }
}

public extension Publisher where Failure: Error {
  var stream: AsyncThrowingStream<Output, Error> {
    AsyncThrowingStream<Output, Error> { continuation in
      let cancellable = self.sink { completion in
        switch completion {
        case .finished:
          continuation.finish()
        case let .failure(error):
          continuation.finish(throwing: error)
        }
      } receiveValue: { value in
        continuation.yield(value)
      }
      continuation.onTermination = { _ in
        cancellable.cancel()
      }
    }
  }
}
