import Foundation

final class AccountManager {
    struct Profile: Codable, Equatable {
        let mid: Int
        var username: String
        var avatar: String
    }

    struct Account: Codable, Equatable {
        var token: LoginToken
        var profile: Profile
        var cookies: [StoredCookie]
        var lastActiveAt: Date
    }

    static let shared = AccountManager()
    static let didUpdateNotification = Notification.Name.accountDidUpdate

    private let accountsKey = "app.multiple.accounts"
    private let activeKey = "app.multiple.accounts.active"
    /// UserDefaults 现在只存非敏感的 activeMID；账号列表(含 token/cookies)在 Keychain
    private let metadataStorage = UserDefaults.standard
    /// 可重入锁：removeAccount 等公开方法内部会再次进入加锁区；锁内只碰内存态与持久化，
    /// CookieHandler/NotificationCenter 等外部副作用一律放锁外执行
    private let lock = NSRecursiveLock()

    private var storedAccounts: [Account] = []
    private var activeMID: Int?

    private init() {
        loadFromStorage()
    }

    // MARK: - Public

    var accounts: [Account] {
        withLock { storedAccounts.sorted(by: { $0.lastActiveAt > $1.lastActiveAt }) }
    }

    var activeAccount: Account? {
        withLock {
            guard let activeMID else { return nil }
            return storedAccounts.first(where: { $0.profile.mid == activeMID })
        }
    }

    var isLoggedIn: Bool {
        withLock { activeAccount != nil }
    }

    func bootstrap() {
        let needPickFirst = withLock {
            if activeMID == nil {
                activeMID = storedAccounts.sorted(by: { $0.lastActiveAt > $1.lastActiveAt }).first?.profile.mid
                persistActiveMID()
            }
            return activeMID != nil
        }
        if needPickFirst {
            applyActiveAccountCookies()
        }
    }

    @discardableResult
    @MainActor
    func registerAccount(token: LoginToken, cookies: [HTTPCookie]) async -> Account {
        let storedCookies = cookies.map(StoredCookie.init)
        let profile: Profile
        do {
            let info = try await fetchProfile(using: token)
            profile = Profile(mid: info.mid, username: info.uname, avatar: info.face)
        } catch {
            Logger.warn("[account] 拉取个人信息失败，使用兜底资料: \(error)")
            profile = Profile(mid: token.mid, username: "UID \(token.mid)", avatar: "")
        }
        var newAccount = Account(token: token,
                                 profile: profile,
                                 cookies: storedCookies,
                                 lastActiveAt: Date())
        withLock {
            upsert(account: newAccount)
            activeMID = newAccount.profile.mid
            updateAccount(mid: newAccount.profile.mid) { account in
                account.cookies = storedCookies
                account.lastActiveAt = Date()
                newAccount = account
            }
            persistAll()
        }
        applyActiveAccountCookies()
        notifyChange()
        return newAccount
    }

    func setActiveAccount(_ account: Account) {
        setActiveAccount(mid: account.profile.mid)
    }

    func setActiveAccount(mid: Int, applyingCookies: Bool = true, notify: Bool = true) {
        let switched = withLock {
            guard storedAccounts.contains(where: { $0.profile.mid == mid }) else { return false }
            activeMID = mid
            updateAccount(mid: mid) { account in
                account.lastActiveAt = Date()
            }
            persistAll()
            return true
        }
        guard switched else { return }
        if applyingCookies {
            applyActiveAccountCookies()
        }
        if notify {
            notifyChange()
        }
    }

    func updateActiveAccount(token: LoginToken, cookies: [HTTPCookie]? = nil) {
        let didUpdate = withLock {
            guard let mid = activeMID,
                  let index = storedAccounts.firstIndex(where: { $0.profile.mid == mid }) else { return false }
            storedAccounts[index].token = token
            storedAccounts[index].lastActiveAt = Date()
            if let cookies {
                storedAccounts[index].cookies = cookies.map(StoredCookie.init)
            }
            persistAll()
            return true
        }
        if didUpdate {
            notifyChange()
        }
    }

    func updateActiveProfile(username: String, avatar: String) {
        let didUpdate = withLock {
            guard let mid = activeMID,
                  let index = storedAccounts.firstIndex(where: { $0.profile.mid == mid }) else { return false }
            storedAccounts[index].profile.username = username
            storedAccounts[index].profile.avatar = avatar
            persistAll()
            return true
        }
        if didUpdate {
            notifyChange()
        }
    }

    @MainActor
    func refreshActiveAccountProfile() async {
        do {
            let info = try await fetchProfile()
            updateActiveProfile(username: info.uname, avatar: info.face)
        } catch {
            Logger.warn("[account] 刷新个人信息失败: \(error)")
        }
    }

    func syncActiveAccountCookies() {
        let mid = withLock { activeMID }
        guard let mid else { return }
        let cookies = CookieHandler.shared.currentStoredCookies()
        withLock {
            updateAccount(mid: mid) { account in
                account.cookies = cookies
            }
            persistAll()
        }
    }

    @discardableResult
    func removeAccount(_ account: Account) -> Bool {
        withLock {
            storedAccounts.removeAll(where: { $0.profile.mid == account.profile.mid })
            persistAccounts()
        }
        let removedActive = withLock { activeMID == account.profile.mid }
        if removedActive {
            withLock {
                activeMID = nil
                persistActiveMID()
            }
            let next = withLock { storedAccounts.sorted(by: { $0.lastActiveAt > $1.lastActiveAt }).first }
            if let next {
                setActiveAccount(mid: next.profile.mid)
            } else {
                CookieHandler.shared.removeCookie()
                notifyChange()
            }
        } else {
            notifyChange()
        }
        return withLock { !storedAccounts.isEmpty }
    }

    func removeAllAccounts() {
        withLock {
            storedAccounts.removeAll()
            persistAccounts()
            activeMID = nil
            persistActiveMID()
        }
        CookieHandler.shared.removeCookie()
        notifyChange()
    }

    func handleAuthenticationFailure() {
        guard let account = withLock({ activeAccount }) else { return }
        _ = removeAccount(account)
    }

    // MARK: - Private helpers

    private func fetchProfile(using token: LoginToken? = nil) async throws -> WebRequest.NavInfo {
        try await WebRequest.requestLoginInfo(accessKey: token?.accessToken)
    }

    private func applyActiveAccountCookies() {
        guard let cookies = withLock({ activeAccount })?.cookies else { return }
        CookieHandler.shared.replaceCookies(with: cookies)
    }

    private func loadFromStorage() {
        // 历史版本把账号列表明文放在 UserDefaults；读到即迁入 Keychain 并删除旧值
        if let data = KeychainStore.data(forKey: accountsKey) {
            storedAccounts = (try? JSONDecoder().decode([Account].self, from: data)) ?? []
        } else if let legacy = metadataStorage.data(forKey: accountsKey) {
            storedAccounts = (try? JSONDecoder().decode([Account].self, from: legacy)) ?? []
            persistAccounts()
            metadataStorage.removeObject(forKey: accountsKey)
            Logger.info("[account] 已将账号凭证从 UserDefaults 迁移至 Keychain")
        }
        withLock {
            if metadataStorage.object(forKey: activeKey) != nil {
                let mid = metadataStorage.integer(forKey: activeKey)
                activeMID = storedAccounts.contains(where: { $0.profile.mid == mid }) ? mid : nil
            }
        }
    }

    private func persistAll() {
        persistAccounts()
        persistActiveMID()
    }

    /// 调用方须已持有 lock
    private func persistAccounts() {
        do {
            let data = try JSONEncoder().encode(storedAccounts)
            KeychainStore.setData(data, forKey: accountsKey)
        } catch {
            // 编码失败时保留旧数据，绝不静默清空账号列表
            Logger.warn("[account] 账号列表持久化失败: \(error)")
        }
    }

    /// 调用方须已持有 lock
    private func persistActiveMID() {
        if let activeMID {
            metadataStorage.set(activeMID, forKey: activeKey)
        } else {
            metadataStorage.removeObject(forKey: activeKey)
        }
    }

    /// 调用方须已持有 lock
    private func upsert(account: Account) {
        if let index = storedAccounts.firstIndex(where: { $0.profile.mid == account.profile.mid }) {
            storedAccounts[index] = account
        } else {
            storedAccounts.append(account)
        }
    }

    /// 调用方须已持有 lock
    private func updateAccount(mid: Int, update: (inout Account) -> Void) {
        guard let index = storedAccounts.firstIndex(where: { $0.profile.mid == mid }) else { return }
        update(&storedAccounts[index])
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: AccountManager.didUpdateNotification, object: self)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
