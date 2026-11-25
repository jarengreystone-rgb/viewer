import Foundation
import Testing

@MainActor
struct LoginCredentialStoreTests {
    @Test func savingIsOptInAndNeverIncludesAuthenticationCode() async throws {
        let store = MemoryLoginCredentialStore()
        let form = LoginAccountForm(store: store)
        form.username = "Example Resident"
        form.password = "fixture-password"
        form.token = "123456"
        let first = await form.prepareCredentials(start: "last", agreeToTerms: true)
        #expect(first?.token == "123456")
        #expect(await store.load(for: .secondLife) == nil)

        form.rememberAccount = true
        _ = await form.prepareCredentials(start: "last", agreeToTerms: true)
        let saved = try #require(await store.load(for: .secondLife))
        #expect(saved.username == "Example Resident")
        #expect(saved.password == "fixture-password")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: String]
        #expect(Set(encoded?.keys.map { $0 } ?? []) == ["username", "password"])
    }

    @Test func savedAccountRestoresInNewFormAndGridsStaySeparate() async throws {
        let store = MemoryLoginCredentialStore()
        await store.save(SavedLoginAccount(username: "Main", password: "main-secret"), for: .secondLife)
        await store.save(SavedLoginAccount(username: "Beta", password: "beta-secret"), for: .beta)
        let form = LoginAccountForm(store: store)
        await form.loadSavedAccount(for: .secondLife)
        #expect(form.username == "Main")
        #expect(form.password == "main-secret")
        #expect(form.rememberAccount)
        #expect(form.token.isEmpty)
        form.grid = .beta
        await form.loadSavedAccount(for: .beta)
        #expect(form.username == "Beta")
        #expect(form.password == "beta-secret")
        await form.forgetAccount(for: .beta, clearForm: true)
        #expect(form.username.isEmpty)
        #expect(form.password.isEmpty)
        #expect(await store.load(for: .beta) == nil)
        #expect(await store.load(for: .secondLife)?.username == "Main")
        #expect(!form.rememberAccount)
    }

    @Test func storageFailureDoesNotSilentlyProceed() async {
        let form = LoginAccountForm(store: FailingLoginCredentialStore())
        form.username = "Example"
        form.password = "fixture-password"
        form.rememberAccount = true
        let credentials = await form.prepareCredentials(start: "last", agreeToTerms: true)
        #expect(credentials == nil)
        #expect(form.storageError != nil)
        #expect(!form.isSaving)
        #expect(!form.hasSavedAccount)
    }

    @Test func togglingRememberOffRemovesSavedAccount() async throws {
        let store = MemoryLoginCredentialStore()
        await store.save(SavedLoginAccount(username: "Example", password: "fixture-password"), for: .secondLife)
        let form = LoginAccountForm(store: store)
        await form.loadSavedAccount(for: .secondLife)
        form.rememberAccount = false
        for _ in 0..<50 {
            if await store.load(for: .secondLife) == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await store.load(for: .secondLife) == nil)
        #expect(!form.hasSavedAccount)
    }

}

private actor MemoryLoginCredentialStore: LoginCredentialStoring {
    private var accounts: [Grid: SavedLoginAccount] = [:]
    func load(for grid: Grid) -> SavedLoginAccount? { accounts[grid] }
    func save(_ account: SavedLoginAccount, for grid: Grid) { accounts[grid] = account }
    func remove(for grid: Grid) { accounts.removeValue(forKey: grid) }
}

private struct FailingLoginCredentialStore: LoginCredentialStoring {
    func load(for grid: Grid) async throws -> SavedLoginAccount? { throw CredentialStorageError(status: -1) }
    func save(_ account: SavedLoginAccount, for grid: Grid) async throws { throw CredentialStorageError(status: -1) }
    func remove(for grid: Grid) async throws { throw CredentialStorageError(status: -1) }
}
