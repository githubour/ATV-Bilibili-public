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
        let previousMID = withLock { activeMID }
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
        // 真正换号（前后 mid 不同）才通知清理随账号走的缓存；同账号重复 set 不触发
        if let previousMID, previousMID != mid {
            NotificationCenter.default.post(name: .accountDidSwitch, object: self)
        }
    }

    /// 按 mid 更新 token/cookie，不依赖“完成时谁是活动账号”。
    /// 刷新/换号并发时，异步结果必须回到发起刷新的那个账号，否则会把 A 的凭据写给 B。
    func updateStoredAccountToken(mid: Int, token: LoginToken, cookies: [HTTPCookie]? = nil) {
        let didUpdate = withLock {
            guard let index = storedAccounts.firstIndex(where: { $0.profile.mid == mid }) else { return false }
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
        CookieHandler.shared.removeAccountCookies(mid: account.profile.mid)
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
                CookieHandler.shared.activateAccount(mid: nil, cookies: [])
                notifyChange()
            }
            // 被移除的正是当前账号：清随账号走的缓存（前面已把 activeMID 置 nil，setActiveAccount 不会发此通知）
            NotificationCenter.default.post(name: .accountDidSwitch, object: self)
        } else {
            notifyChange()
        }
        return withLock { !storedAccounts.isEmpty }
    }

    /// 登录失效只做标记/通知，不删除账号。
    /// 旧实现按“当前活动账号”删除，切号期间会把另一个号删掉；且 refresh_token
    /// 尚可恢复时删号会直接丢凭据。返回该 mid 是否仍是当前活动账号，供调用方决定是否回登录页。
    @discardableResult
    func handleAuthenticationFailure(mid: Int?) -> Bool {
        guard let mid,
              withLock({ storedAccounts.contains(where: { $0.profile.mid == mid }) })
        else { return false }
        Logger.warn("[account] \(mid) 登录状态失效，保留账号等待重新登录")
        notifyChange()
        return withLock { activeMID == mid }
    }

    // MARK: - Private helpers

    private func fetchProfile(using token: LoginToken? = nil) async throws -> WebRequest.NavInfo {
        try await WebRequest.requestLoginInfo(accessKey: token?.accessToken)
    }

    private func applyActiveAccountCookies() {
        let account = withLock({ activeAccount })
        CookieHandler.shared.activateAccount(mid: account?.profile.mid,
                                             cookies: account?.cookies ?? [])
    }

    private func loadFromStorage() {
        // 旧版本把 cookie 写进 HTTPCookieStorage.shared；新版本改为自管后，
        // 共享存储里的旧 cookie 仍可能被默认 URLSession/AF 会话带出，启动时清一次。
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
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
