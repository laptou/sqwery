import Combine
import Foundation

public actor MutationClient {
  public static let shared = MutationClient()
  
  private let subject = PassthroughSubject<(mutationKey: AnyHashable, mutationState: Any), Never>()

  public func mutate<K: MutationKey>(_ key: K, parameter: K.Parameter) async -> AsyncStream<RequestState<K.Result, K.Progress>> {
    var state = RequestState<K.Result, K.Progress>()
    state.status = .pending(progress: nil)
    subject.send((AnyHashable(key), state))

    Task {
      do {
        state.retryCount = 0

        while true {
          do {
            let result = try await key.run(client: self, parameter: parameter, onProgress: { progress in
              state.status = .pending(progress: progress)
              self.subject.send((AnyHashable(key), state))
            })
            
            state.status = .success(value: result)
            subject.send((AnyHashable(key), state))
            
            await key.onSuccess(client: self, parameter: parameter, result: result)
            
            break
          } catch {
            state.retryCount += 1

            if state.retryCount >= key.retryLimit {
              throw error
            }

            try? await Task.sleep(for: key.retryDelay)
          }
        }

      } catch {
        state.status = .error(error: error)
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
