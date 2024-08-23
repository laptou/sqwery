import Combine
import Foundation

public actor MutationClient {
  private let subject = PassthroughSubject<(mutationKey: AnyHashable, mutationState: Any), Never>()

  func mutate<K: MutationKey>(_ key: K, parameter: K.Parameter) async -> AnyPublisher<RequestState<K.Result>, Never> {
    let state = RequestState<K.Result>()
    state.status = .pending

    subject.send((AnyHashable(key), state))

    Task {
      do {
        var attempt = 0
        var result: K.Result?

        while true {
          do {
            result = try await key.run(parameter: parameter)
            break
          } catch {
            attempt += 1

            if attempt >= key.retryLimit {
              throw error
            }

            try? await Task.sleep(for: key.retryDelay)
          }
        }

        state.status = .success(value: result!)
        subject.send((AnyHashable(key), state))
      } catch {
        state.status = .error(error: error)
        subject.send((AnyHashable(key), state))
      }
    }

    return subject
      .filter { $0.mutationKey == AnyHashable(key) }
      .compactMap { $0.mutationState as? RequestState<K.Result> }
      .eraseToAnyPublisher()
  }
}
