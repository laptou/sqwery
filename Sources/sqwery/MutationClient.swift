import Combine
import Foundation

public actor MutationClient {
  public static let shared = MutationClient()
  
  private let subject = PassthroughSubject<(mutationKey: AnyHashable, mutationState: Any), Never>()

  func mutate<K: MutationKey>(_ key: K, parameter: K.Parameter) async -> AnyPublisher<RequestState<K.Result, K.Progress>, Never> {
    var state = RequestState<K.Result, K.Progress>()
    state.status = .pending(progress: nil)
    subject.send((AnyHashable(key), state))

    Task {
      do {
        var attempt = 0
        var result: K.Result?

        while true {
          do {
            result = try await key.run(parameter: parameter, onProgress: { progress in
              state.status = .pending(progress: progress)
              self.subject.send((AnyHashable(key), state))
            })
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
      .compactMap { $0.mutationState as? RequestState<K.Result, K.Progress> }
      .eraseToAnyPublisher()
  }
}
