// Cat: email-code and username+password sign-in screen.
//
// Same protocol as H5 / Android (server: teamgram bff authorization identity_auth.go):
//   auth.sendCode(phone_number: "email:<addr>" | "user:<name>")
//   auth.signIn(phone_code: mailed code | password) -> authorization | authorizationSignUpRequired
//   auth.signUp(first_name)
// The email code / sign-up screens are the stock ones; this screen only collects
// the identifier (and password) and asks for password confirmation on sign-up.

import Foundation
import UIKit
import Display
import AsyncDisplayKit
import TelegramPresentationData

public final class AuthorizationIdentityController: ViewController {
    public enum Mode: Int {
        case email = 0
        case user = 1
    }

    private let presentationData: PresentationData
    private let isChinese: Bool
    private(set) var mode: Mode

    /// (mode, prefixed identifier, password or "")
    var submit: ((Mode, String, String) -> Void)?
    /// user confirmed the password for a new username
    var confirmSignUp: (() -> Void)?
    /// user picked the "phone" segment
    var switchToPhone: (() -> Void)?

    private let segmented: UISegmentedControl
    private let scrollView = UIScrollView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let idField: PaddedTextField
    private let passwordField: PaddedTextField
    private let confirmField: PaddedTextField
    private let errorLabel = UILabel()
    private let button = UIButton(type: .custom)
    private let buttonGradient = CAGradientLayer()
    private let activity = UIActivityIndicatorView(style: .medium)
    private let hintLabel = UILabel()

    private var awaitingConfirm = false
    private var pendingPassword = ""
    private var validLayout: ContainerViewLayout?

    public var inProgress: Bool = false {
        didSet {
            self.button.isEnabled = !self.inProgress
            self.button.alpha = self.inProgress ? 0.8 : 1.0
            if self.inProgress {
                self.activity.startAnimating()
            } else {
                self.activity.stopAnimating()
            }
        }
    }

    public init(presentationData: PresentationData, mode: Mode, back: @escaping () -> Void) {
        self.presentationData = presentationData
        self.mode = mode
        let zh = (Locale.preferredLanguages.first ?? "").hasPrefix("zh")
        self.isChinese = zh
        self.segmented = UISegmentedControl(items: zh ? ["邮箱", "账号", "手机"] : ["Email", "Username", "Phone"])
        let theme = presentationData.theme
        self.idField = PaddedTextField(theme: theme)
        self.passwordField = PaddedTextField(theme: theme)
        self.confirmField = PaddedTextField(theme: theme)

        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: AuthorizationSequenceController.navigationBarTheme(presentationData.theme), strings: NavigationBarStrings(presentationStrings: presentationData.strings)))

        self.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)
        self.hasActiveInput = true
        self.statusBar.statusBarStyle = presentationData.theme.intro.statusBarStyle.style
        self.navigationBar?.backPressed = {
            back()
        }

        let titleContainer = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 260.0, height: 44.0))
        self.segmented.selectedSegmentIndex = mode.rawValue
        self.segmented.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        self.segmented.frame = CGRect(x: 0.0, y: 6.0, width: 240.0, height: 32.0)
        self.segmented.addTarget(self, action: #selector(self.segmentChanged), for: .valueChanged)
        titleContainer.addSubview(self.segmented)
        self.navigationItem.titleView = titleContainer
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func s(_ zh: String, _ en: String) -> String {
        return self.isChinese ? zh : en
    }

    override public func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.presentationData.theme.list.plainBackgroundColor
        self.displayNodeDidLoad()

        let theme = self.presentationData.theme
        let view = self.displayNode.view
        self.scrollView.alwaysBounceVertical = true
        self.scrollView.keyboardDismissMode = .interactive
        view.addSubview(self.scrollView)

        self.titleLabel.font = Font.bold(28.0)
        self.titleLabel.textColor = theme.list.itemPrimaryTextColor
        self.titleLabel.textAlignment = .center
        self.titleLabel.text = self.s("欢迎来到 Cat", "Welcome to Cat")

        self.subtitleLabel.font = Font.regular(16.0)
        self.subtitleLabel.textColor = theme.list.itemSecondaryTextColor
        self.subtitleLabel.textAlignment = .center
        self.subtitleLabel.numberOfLines = 0

        for field in [self.idField, self.passwordField, self.confirmField] {
            field.delegate = self
            field.keyboardAppearance = theme.rootController.keyboardColor.keyboardAppearance
            field.addTarget(self, action: #selector(self.textChanged), for: .editingChanged)
        }
        self.passwordField.isSecureTextEntry = true
        self.passwordField.textContentType = .password
        self.passwordField.setPlaceholder(self.s("密码", "Password"))
        self.confirmField.isSecureTextEntry = true
        self.confirmField.textContentType = .newPassword
        self.confirmField.setPlaceholder(self.s("再次输入密码", "Confirm password"))

        self.errorLabel.font = Font.regular(14.0)
        self.errorLabel.textColor = theme.list.itemDestructiveColor
        self.errorLabel.numberOfLines = 0
        self.errorLabel.textAlignment = .center

        self.buttonGradient.colors = [UIColor(rgb: 0x4f7cff).cgColor, UIColor(rgb: 0x8b5cf6).cgColor]
        self.buttonGradient.startPoint = CGPoint(x: 0.0, y: 0.0)
        self.buttonGradient.endPoint = CGPoint(x: 1.0, y: 1.0)
        self.buttonGradient.cornerRadius = 14.0
        self.button.layer.insertSublayer(self.buttonGradient, at: 0)
        self.button.layer.cornerRadius = 14.0
        self.button.titleLabel?.font = Font.semibold(17.0)
        self.button.setTitleColor(.white, for: .normal)
        self.button.addTarget(self, action: #selector(self.buttonPressed), for: .touchUpInside)
        self.activity.hidesWhenStopped = true
        self.activity.color = .white
        self.button.addSubview(self.activity)

        self.hintLabel.font = Font.regular(13.0)
        self.hintLabel.textColor = theme.list.itemSecondaryTextColor
        self.hintLabel.textAlignment = .center
        self.hintLabel.numberOfLines = 0

        for v in [self.titleLabel, self.subtitleLabel, self.idField, self.passwordField, self.confirmField, self.errorLabel, self.button, self.hintLabel] as [UIView] {
            self.scrollView.addSubview(v)
        }
        self.applyMode()
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.idField.becomeFirstResponder()
    }

    private func applyMode() {
        guard self.isNodeLoaded else {
            return
        }
        self.awaitingConfirm = false
        self.confirmField.text = ""
        self.errorLabel.text = nil
        self.idField.isEnabled = true
        self.passwordField.isEnabled = true
        switch self.mode {
        case .email:
            self.subtitleLabel.text = self.s("输入邮箱，我们会发送 6 位验证码", "We'll email you a 6-digit code")
            self.idField.setPlaceholder(self.s("邮箱地址", "Email address"))
            self.idField.keyboardType = .emailAddress
            self.idField.textContentType = .emailAddress
            self.idField.returnKeyType = .go
            self.button.setTitle(self.s("获取验证码", "Send code"), for: .normal)
            self.hintLabel.text = self.s("未注册的邮箱验证后将自动创建账号", "New emails get an account automatically")
        case .user:
            self.subtitleLabel.text = self.s("登录或注册，一步完成", "Sign in or create an account in one step")
            self.idField.setPlaceholder(self.s("用户名", "Username"))
            self.idField.keyboardType = .asciiCapable
            self.idField.textContentType = .username
            self.idField.returnKeyType = .next
            self.button.setTitle(self.s("登录 / 注册", "Sign in / Sign up"), for: .normal)
            self.hintLabel.text = self.s("未注册的用户名将为你创建新账号", "Unregistered usernames will create a new account")
        }
        self.idField.autocapitalizationType = .none
        self.idField.autocorrectionType = .no
        self.idField.reloadInputViews()
        if let layout = self.validLayout {
            self.containerLayoutUpdated(layout, transition: .animated(duration: 0.25, curve: .easeInOut))
        }
    }

    /// Called by the sequence controller when the username is free.
    func showUserConfirm(username: String, password: String) {
        self.awaitingConfirm = true
        self.pendingPassword = password
        self.idField.isEnabled = false
        self.passwordField.isEnabled = false
        self.subtitleLabel.text = self.s("用户名 @\(username) 还未注册，再次输入密码即可创建账号", "@\(username) is available. Confirm your password to create the account.")
        self.button.setTitle(self.s("下一步", "Continue"), for: .normal)
        self.hintLabel.text = nil
        self.errorLabel.text = nil
        if let layout = self.validLayout {
            self.containerLayoutUpdated(layout, transition: .animated(duration: 0.25, curve: .easeInOut))
        }
        self.confirmField.becomeFirstResponder()
    }

    func showError(_ text: String) {
        self.errorLabel.text = text
        HapticFeedback().error()
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.values = [0.0, -8.0, 8.0, -5.0, 5.0, 0.0]
        anim.duration = 0.32
        self.errorLabel.layer.add(anim, forKey: "shake")
        if let layout = self.validLayout {
            self.containerLayoutUpdated(layout, transition: .immediate)
        }
    }

    @objc private func segmentChanged() {
        let index = self.segmented.selectedSegmentIndex
        if index == 2 {
            self.segmented.selectedSegmentIndex = self.mode.rawValue
            self.view.endEditing(true)
            self.switchToPhone?()
            return
        }
        if let mode = Mode(rawValue: index), mode != self.mode {
            self.mode = mode
            self.idField.text = ""
            self.passwordField.text = ""
            self.applyMode()
            self.idField.becomeFirstResponder()
        }
    }

    @objc private func textChanged() {
        if self.errorLabel.text != nil {
            self.errorLabel.text = nil
            if let layout = self.validLayout {
                self.containerLayoutUpdated(layout, transition: .immediate)
            }
        }
    }

    @objc private func buttonPressed() {
        if self.inProgress {
            return
        }
        if self.awaitingConfirm {
            if (self.confirmField.text ?? "") != self.pendingPassword {
                self.showError(self.s("两次输入的密码不一致", "Passwords do not match"))
                return
            }
            self.view.endEditing(true)
            self.confirmSignUp?()
            return
        }
        let raw = (self.idField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch self.mode {
        case .email:
            if raw.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) == nil {
                self.showError(self.s("请输入有效的邮箱地址", "Enter a valid email address"))
                return
            }
            self.view.endEditing(true)
            self.submit?(.email, "email:" + raw, "")
        case .user:
            if raw.range(of: "^[a-z][a-z0-9_]{4,31}$", options: .regularExpression) == nil {
                self.showError(self.s("用户名需 5-32 位，以字母开头，仅含小写字母、数字和下划线", "5-32 chars, start with a letter; a-z, 0-9 and _ only"))
                return
            }
            let password = self.passwordField.text ?? ""
            if password.count < 8 {
                self.showError(self.s("密码至少 8 位", "At least 8 characters"))
                return
            }
            self.view.endEditing(true)
            self.submit?(.user, "user:" + raw, password)
        }
    }

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.validLayout = layout

        let navigationHeight = self.navigationLayout(layout: layout).navigationFrame.maxY
        let insets = layout.insets(options: [.input])
        self.scrollView.frame = CGRect(x: 0.0, y: navigationHeight, width: layout.size.width, height: max(0.0, layout.size.height - navigationHeight - insets.bottom))

        let side: CGFloat = 24.0 + layout.safeInsets.left
        let width = min(420.0, layout.size.width - side * 2.0)
        let x = floor((layout.size.width - width) / 2.0)
        var y: CGFloat = 32.0

        let titleHeight = self.titleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        transition.updateFrame(view: self.titleLabel, frame: CGRect(x: x, y: y, width: width, height: titleHeight))
        y += titleHeight + 10.0
        let subHeight = self.subtitleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        transition.updateFrame(view: self.subtitleLabel, frame: CGRect(x: x, y: y, width: width, height: subHeight))
        y += subHeight + 28.0

        transition.updateFrame(view: self.idField, frame: CGRect(x: x, y: y, width: width, height: 54.0))
        y += 54.0 + 12.0

        let showPassword = self.mode == .user
        self.passwordField.isHidden = !showPassword
        if showPassword {
            transition.updateFrame(view: self.passwordField, frame: CGRect(x: x, y: y, width: width, height: 54.0))
            y += 54.0 + 12.0
        }
        self.confirmField.isHidden = !self.awaitingConfirm
        if self.awaitingConfirm {
            transition.updateFrame(view: self.confirmField, frame: CGRect(x: x, y: y, width: width, height: 54.0))
            y += 54.0 + 12.0
        }

        if let text = self.errorLabel.text, !text.isEmpty {
            let h = self.errorLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            self.errorLabel.frame = CGRect(x: x, y: y, width: width, height: h)
            y += h + 10.0
        } else {
            self.errorLabel.frame = CGRect(x: x, y: y, width: width, height: 0.0)
        }

        y += 6.0
        transition.updateFrame(view: self.button, frame: CGRect(x: x, y: y, width: width, height: 52.0))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.buttonGradient.frame = CGRect(x: 0.0, y: 0.0, width: width, height: 52.0)
        CATransaction.commit()
        self.activity.frame = CGRect(x: width - 40.0, y: 16.0, width: 20.0, height: 20.0)
        y += 52.0 + 14.0

        let hintHeight = self.hintLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        transition.updateFrame(view: self.hintLabel, frame: CGRect(x: x, y: y, width: width, height: hintHeight))
        y += hintHeight + 24.0

        self.scrollView.contentSize = CGSize(width: layout.size.width, height: y)
    }
}

extension AuthorizationIdentityController: UITextFieldDelegate {
    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === self.idField && self.mode == .user && !self.awaitingConfirm {
            self.passwordField.becomeFirstResponder()
        } else {
            self.buttonPressed()
        }
        return false
    }
}

private final class PaddedTextField: UITextField {
    private let theme: PresentationTheme

    init(theme: PresentationTheme) {
        self.theme = theme
        super.init(frame: .zero)
        self.font = Font.regular(17.0)
        self.textColor = theme.list.itemPrimaryTextColor
        self.tintColor = theme.list.itemAccentColor
        self.backgroundColor = theme.list.itemPlaceholderTextColor.withAlphaComponent(0.12)
        self.layer.cornerRadius = 14.0
        self.clearButtonMode = .whileEditing
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setPlaceholder(_ text: String) {
        self.attributedPlaceholder = NSAttributedString(string: text, attributes: [.foregroundColor: self.theme.list.itemPlaceholderTextColor, .font: Font.regular(17.0)])
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect {
        return bounds.insetBy(dx: 16.0, dy: 0.0)
    }

    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        return bounds.insetBy(dx: 16.0, dy: 0.0)
    }

    override func placeholderRect(forBounds bounds: CGRect) -> CGRect {
        return bounds.insetBy(dx: 16.0, dy: 0.0)
    }
}
