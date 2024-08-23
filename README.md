# `sqwery`

Sqwery is a Swift library that provides a powerful and flexible way to manage asynchronous data fetching and state management in SwiftUI applications. 
It offers a clean and declarative API for handling queries and mutations, inspired by [TanStack Query](https://tanstack.com/query/latest).

## Features

- Declarative query and mutation definitions
- Automatic caching and invalidation
- Retry logic with customizable delays
- SwiftUI integration with property wrappers
- Support for HTTP requests with Alamofire

## Usage

### Defining a Query

First, define your query by conforming to the `QueryKey` protocol:

```swift
struct UserQuery: QueryKey {
    let userId: Int
    
    var resultLifetime: Duration { .seconds(60) }
    var retryDelay: Duration { .seconds(5) }
    var retryLimit: Int { 3 }
    
    func run() async throws -> User {
        // Fetch user data from an API
        let url = URL(string: "https://api.example.com/users/\(userId)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(User.self, from: data)
    }
}
```

### Using Queries in SwiftUI

Use the `@Query` property wrapper to integrate your query with SwiftUI:

```swift
struct UserView: View {
    @Query(UserQuery(userId: 1), queryClient: queryClient)
    var userQuery

    var body: some View {
        switch userQuery {
        case .success(let user):
            Text(user.name)
        case .error(let error):
            Text("Error: \(error.localizedDescription)")
        case .pending:
            ProgressView()
        case .idle:
            Text("Idle")
        }
    }
}
```

### Defining a Mutation

Define a mutation by conforming to the `MutationKey` protocol:

```swift
struct UpdateUserMutation: MutationKey {
    typealias Parameter = UpdateUserParams
    typealias Result = User

    var retryDelay: Duration { .seconds(5) }
    var retryLimit: Int { 3 }

    func run(parameter: UpdateUserParams) async throws -> User {
        // Update user data via API
        let url = URL(string: "https://api.example.com/users/\(parameter.userId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = try JSONEncoder().encode(parameter)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(User.self, from: data)
    }
}
```

### Using Mutations in SwiftUI

Use the `@Mutation` property wrapper to integrate your mutation with SwiftUI:

```swift
struct UpdateUserView: View {
    @Mutation(UpdateUserMutation(), mutationClient: mutationClient)
    var updateUserMutation

    @State private var name = ""

    var body: some View {
        VStack {
            TextField("Name", text: $name)
            Button("Update User") {
                let params = UpdateUserParams(userId: 1, name: name)
                $updateUserMutation.mutate(parameter: params)
            }
            
            switch updateUserMutation {
            case .success(let user):
                Text("Updated: \(user.name)")
            case .error(let error):
                Text("Error: \(error.localizedDescription)")
            case .pending:
                ProgressView()
            case .idle:
                EmptyView()
            }
        }
    }
}
```

### HTTP Queries and Mutations

Sqwery provides convenience protocols for HTTP queries and mutations using Alamofire:

```swift
struct FetchUserQuery: HttpQueryKey {
    let userId: Int
    
    var url: String { "https://api.example.com/users/\(userId)" }
    var method: HTTPMethod { .get }
    
    typealias Result = User
}

struct CreateUserMutation: HttpJsonMutationKey {
    typealias Body = CreateUserParams
    typealias Result = User
    
    var url: String { "https://api.example.com/users" }
    var method: HTTPMethod { .post }
    
    func bodyData(for parameter: CreateUserParams) throws -> CreateUserParams {
        parameter
    }
}
```

## Advanced Usage

### Query Invalidation

You can invalidate queries to force a refresh:

```swift
await queryClient.invalidate(key: UserQuery(userId: 1))
```

### Custom Caching

Sqwery uses an internal cache to store query results. You can customize caching behavior by modifying the `resultLifetime` property of your queries.

