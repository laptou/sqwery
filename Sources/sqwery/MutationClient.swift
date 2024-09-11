import Combine
import Foundation
import os

public actor MutationClient {
  public static let shared = MutationClient()

  private let subject = PassthroughSubject<(mutationKey: AnyHashable, mutationState: Any), Never>()

  public func mutate<K: MutationKey>(_ key: K, parameter: K.Parameter) async -> AsyncStream<RequestState<K.Result, K.Progress>> {
    let logger = Logger(
      subsystem: "sqwery",
      category: "mutation \(String(describing: key))"
    )

    var state = RequestState<K.Result, K.Progress>()
    state.queryStatus = .pending(progress: nil)
    subject.send((AnyHashable(key), state))

    logger.debug("mutation loop starting")

    Task {
      do {
        state.retryCount = 0

        while true {
          if Task.isCancelled {
            logger.debug("mutation cancelled")
            break
          }

          do {
            logger.trace("running mutation")

            let result = try await key.run(client: self, parameter: parameter, onProgress: { progress in
              state.queryStatus = .pending(progress: progress)
              self.subject.send((AnyHashable(key), state))
            })

            logger.debug("mutation success")

            state.queryStatus = .success(value: result)
            subject.send((AnyHashable(key), state))

            await key.onSuccess(client: self, parameter: parameter, result: result)

            break
          } catch {
            state.retryCount += 1

            if state.retryCount >= key.retryLimit {
              throw error
            }

            logger.warning("mutation fail, retrying: \(error)")

            try? await Task.sleep(for: key.retryDelay)
          }
        }

      } catch is CancellationError {
        logger.debug("mutation cancelled")
      } catch {
        logger.error("mutation fail, giving up: \(error)")

        state.queryStatus = .error(error: error)
        subject.send((AnyHashable(key), state))

        await key.onError(client: self, parameter: parameter, error: error)
      }
    }

    return subject
      .filter { $0.mutationKey == AnyHashable(key) }
      .compactMap { $0.mutationState as? RequestState<K.Result, K.Progress> }
      .stream
  }
}
