#!/usr/bin/env python3
"""Apply Cat identity-login changes to a teamgram-ios checkout (run from repo root).

Adds AuthorizationIdentityController (email code / username+password) and wires it
into the phone entry screen (segmented control in the nav bar) and the
AuthorizationSequenceController state machine. Every edit asserts its anchor so an
upstream change fails the build loudly instead of silently skipping.
"""
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = "submodules/AuthorizationUI/Sources"


def patch(path, edits):
    s = open(path, encoding="utf-8").read()
    for old, new in edits:
        n = s.count(old)
        if n != 1:
            sys.exit(f"{path}: anchor found {n}x: {old[:100]!r}")
        s = s.replace(old, new)
    open(path, "w", encoding="utf-8").write(s)
    print("patched", path)


shutil.copy(os.path.join(HERE, "AuthorizationIdentityController.swift"), f"{SRC}/AuthorizationIdentityController.swift")
print("added", f"{SRC}/AuthorizationIdentityController.swift")

# ---------------------------------------------------------------- phone entry: method switcher
patch(f"{SRC}/AuthorizationSequencePhoneEntryController.swift", [
    ("""    public var loginWithNumber: ((String, Bool) -> Void)?
""", """    public var loginWithNumber: ((String, Bool) -> Void)?
    var openIdentityLogin: ((AuthorizationIdentityController.Mode) -> Void)?
    private var identitySegmented: UISegmentedControl?
"""),
    ("""        if !otherAccountPhoneNumbers.1.isEmpty {
            self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "___close", style: .plain, target: self, action: #selector(self.cancelPressed))
        }
""", """        if !otherAccountPhoneNumbers.1.isEmpty {
            self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "___close", style: .plain, target: self, action: #selector(self.cancelPressed))
        }

        let identityZh = (Locale.preferredLanguages.first ?? "").hasPrefix("zh")
        let identitySegmented = UISegmentedControl(items: identityZh ? ["邮箱", "账号", "手机"] : ["Email", "Username", "Phone"])
        identitySegmented.selectedSegmentIndex = 2
        identitySegmented.frame = CGRect(x: 10.0, y: 6.0, width: 240.0, height: 32.0)
        identitySegmented.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        identitySegmented.addTarget(self, action: #selector(self.identitySegmentChanged), for: .valueChanged)
        let identityTitleContainer = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 260.0, height: 44.0))
        identityTitleContainer.addSubview(identitySegmented)
        self.navigationItem.titleView = identityTitleContainer
        self.identitySegmented = identitySegmented
"""),
    ("""    func updateNavigationItems() {""", """    @objc private func identitySegmentChanged() {
        guard let segmented = self.identitySegmented else {
            return
        }
        let index = segmented.selectedSegmentIndex
        segmented.selectedSegmentIndex = 2
        if let mode = AuthorizationIdentityController.Mode(rawValue: index) {
            self.view.endEditing(true)
            self.openIdentityLogin?(mode)
        }
    }

    func updateNavigationItems() {"""),
])

# ---------------------------------------------------------------- sequence controller
patch(f"{SRC}/AuthorizationSequenceController.swift", [
    ("""    private let actionDisposable = MetaDisposable()
""", """    private let actionDisposable = MetaDisposable()
    private weak var identityController: AuthorizationIdentityController?
"""),
    ("""            controller.loginWithNumber = { [weak self, weak controller] number, syncContacts in""",
     """            controller.openIdentityLogin = { [weak self] mode in
                self?.openIdentityLogin(mode: mode)
            }
            controller.loginWithNumber = { [weak self, weak controller] number, syncContacts in"""),
    ("""                case let .confirmationCodeEntry(number, type, phoneCodeHash, timeout, nextType, _, previousCodeEntry, usePrevious):
                    var controllers: [ViewController] = []""",
     """                case let .confirmationCodeEntry(number, type, phoneCodeHash, timeout, nextType, _, previousCodeEntry, usePrevious):
                    if number.hasPrefix("user:") {
                        // username+password: the password is submitted right away by the identity screen
                        break
                    }
                    var controllers: [ViewController] = []"""),
    ("""    private func updateState(state: InnerState) {""", r'''    private var identityIsChinese: Bool {
        return (Locale.preferredLanguages.first ?? "").hasPrefix("zh")
    }

    private func identityText(_ zh: String, _ en: String) -> String {
        return self.identityIsChinese ? zh : en
    }

    private func identityRequestErrorText(_ error: AuthorizationCodeRequestError) -> String {
        switch error {
        case .limitExceeded, .phoneLimitExceeded:
            return self.identityText("操作太频繁，请稍后再试", "Too many attempts, try again later")
        case .timeout:
            return self.identityText("网络连接失败", "Network error")
        case let .generic(info):
            let type = info?.1 ?? ""
            if type.hasPrefix("FLOOD_WAIT_") {
                let seconds = String(type.dropFirst("FLOOD_WAIT_".count))
                return self.identityText("操作太频繁，请 \(seconds) 秒后再试", "Too many attempts. Try again in \(seconds)s")
            }
            switch type {
            case "EMAIL_INVALID":
                return self.identityText("请输入有效的邮箱地址", "Enter a valid email address")
            case "USERNAME_INVALID":
                return self.identityText("用户名需 5-32 位，以字母开头，仅含小写字母、数字和下划线", "5-32 chars, start with a letter; a-z, 0-9 and _ only")
            case "EMAIL_SEND_FAILED":
                return self.identityText("邮件发送失败，请稍后再试", "Could not send the email, try again later")
            case "IDENTITY_LOGIN_DISABLED":
                return self.identityText("服务器暂未开放此登录方式", "This sign-in method is not enabled")
            default:
                return self.identityText("出错了：", "Something went wrong: ") + type
            }
        default:
            return self.presentationData.strings.Login_UnknownError
        }
    }

    private func openIdentityLogin(mode: AuthorizationIdentityController.Mode) {
        if let current = self.identityController, self.viewControllers.contains(where: { $0 === current }) {
            return
        }
        let controller = AuthorizationIdentityController(presentationData: self.presentationData, mode: mode, back: { [weak self] in
            let _ = self?.popViewController(animated: true)
        })
        controller.switchToPhone = { [weak self] in
            let _ = self?.popViewController(animated: true)
        }
        controller.submit = { [weak self, weak controller] mode, identifier, password in
            guard let self, let controller else {
                return
            }
            controller.inProgress = true
            self.actionDisposable.set((sendAuthorizationCode(accountManager: self.sharedContext.accountManager, account: self.account, phoneNumber: identifier, apiId: self.apiId, apiHash: self.apiHash, pushNotificationConfiguration: nil, firebaseSecretStream: self.sharedContext.firebaseSecretStream, syncContacts: true, disableAuthTokens: true, forcedPasswordSetupNotice: { _ in
                return nil
            })
            |> deliverOnMainQueue).startStrict(next: { [weak self, weak controller] result in
                guard let self else {
                    return
                }
                switch result {
                case let .sentCode(account):
                    self.account = account
                    self.inAppPurchaseManager = InAppPurchaseManager(engine: .unauthorized(self.engine))
                    if mode == .user {
                        self.identityAuthorize(password: password, username: String(identifier.dropFirst("user:".count)), controller: controller)
                    } else {
                        controller?.inProgress = false
                    }
                case .loggedIn:
                    controller?.inProgress = false
                }
            }, error: { [weak self, weak controller] error in
                guard let self, let controller else {
                    return
                }
                controller.inProgress = false
                controller.showError(self.identityRequestErrorText(error))
            }))
        }
        self.identityController = controller
        self.pushViewController(controller)
    }

    private func identityAuthorize(password: String, username: String, controller: AuthorizationIdentityController?) {
        self.actionDisposable.set((authorizeWithCode(accountManager: self.sharedContext.accountManager, account: self.account, code: .phoneCode(password), termsOfService: nil, forcedPasswordSetupNotice: { _ in
            return nil
        })
        |> deliverOnMainQueue).startStrict(next: { [weak self, weak controller] result in
            guard let self, let controller else {
                return
            }
            controller.inProgress = false
            switch result {
            case let .signUp(data):
                controller.confirmSignUp = { [weak self] in
                    guard let self else {
                        return
                    }
                    let _ = beginSignUp(account: self.account, data: data).startStandalone()
                }
                controller.showUserConfirm(username: username, password: password)
            case .loggedIn:
                break
            }
        }, error: { [weak self, weak controller] error in
            guard let self, let controller else {
                return
            }
            controller.inProgress = false
            switch error {
            case .limitExceeded:
                controller.showError(self.identityText("尝试次数过多，请稍后再试", "Too many attempts, try again later"))
            case .codeExpired:
                controller.showError(self.identityText("会话已过期，请重试", "Session expired, please try again"))
            default:
                controller.showError(self.identityText("密码不正确", "Incorrect password"))
            }
        }))
    }

    private func updateState(state: InnerState) {'''),
])
# ---------------------------------------------------------------- sideloading without App Groups
# Free-account re-signing (Sideloadly) drops the App Group entitlement: containerURL() returns nil
# and AppDelegate bails out ("Error 2" -> black screen). Fall back to the app's own sandbox so the
# main app works; extensions simply lose shared data.
patch("submodules/TelegramUI/Sources/AppDelegate.swift", [
    ("""        let maybeAppGroupUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName)
""", """        var maybeAppGroupUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName)
        if maybeAppGroupUrl == nil, let fallbackUrl = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("app-group-fallback", isDirectory: true) {
            let _ = try? FileManager.default.createDirectory(at: fallbackUrl, withIntermediateDirectories: true, attributes: nil)
            maybeAppGroupUrl = fallbackUrl
        }
"""),
])
# ---------------------------------------------------------------- sideloading: no Siri / iCloud entitlements
# Free-account re-signing strips com.apple.developer.siri / iCloud; with them enabled the app calls
# INPreferences.siriAuthorizationStatus() at launch and aborts (missing entitlement exception).
import json
cfg_path = "build-system/appstore-configuration.json"
cfg = json.load(open(cfg_path))
cfg["enable_siri"] = False
cfg["enable_icloud"] = False
json.dump(cfg, open(cfg_path, "w"), indent=1)
print("patched", cfg_path, "(siri/icloud off)")
print("OK")
