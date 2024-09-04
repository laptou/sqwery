// https://forums.swift.org/t/how-to-use-combine-publisher-with-swift-concurrency-publisher-values-could-miss-events/67193/9

import Foundation
@preconcurrency import Combine

extension Publisher where Failure == Never {
  public var stream: AsyncStream<Output> {
    AsyncStream { continuation in
      let cancellable = self.sink { completion in
        continuation.finish()
      } receiveValue: { value in
        continuation.yield(value)
      }
      continuation.onTermination = { continuation in
        cancellable.cancel()
      }
    }
  }
}

extension Publisher where Failure: Error {
  public var stream: AsyncThrowingStream<Output, Error> {
    AsyncThrowingStream<Output, Error> { continuation in
      let cancellable = self.sink { completion in
        switch completion {
        case .finished:
          continuation.finish()
        case .failure(let error):
          continuation.finish(throwing: error)
        }
      } receiveValue: { value in
        continuation.yield(value)
      }
      continuation.onTermination = { continuation in
        cancellable.cancel()
      }
    }
  }
}
