import SwiftUI
import UIKit
import Foundation

@MainActor
struct AddAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var vm: AppStore
    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var code: String = ""
    @State private var errorMessage: String = ""
    @State private var isLoading: Bool = false
    @State private var showTwoFactorField: Bool = false
    @State private var showPassword: Bool = false

    @State private var emailTag: Int = 0
    @State private var passwordTag: Int = 1
    @State private var codeTag: Int = 2
    @State private var focusTag: Int? = nil

    @State private var infoMessage: String = ""

    var body: some View {
        NavigationView {
            ZStack {
                themeManager.backgroundColor
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Color.clear.frame(height: 8)

                    ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 0) {

                            VStack(spacing: 20) {
                                Image("AppLogo")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 120, height: 120)
                                    .cornerRadius(12)
                                    .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)

                                VStack(spacing: 8) {
                                    Text("apple_id".localized)
                                        .font(.system(size: 34, weight: .bold))
                                        .foregroundColor(.primary)

                                    Text("login_your_account".localized)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.top, 24)
                            .padding(.bottom, 32)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("apple_id".localized)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                AppleLoginTextField(
                                    text: $email,
                                    placeholder: NSLocalizedString("enter_apple_id", comment: ""),
                                    tag: 0,
                                    keyboardType: .emailAddress,
                                    returnKeyType: .next,
                                    isSecure: false,
                                    contentType: .username,
                                    accent: themeManager.accentColor,
                                    focusTag: $focusTag,
                                    onCommit: { focusTag = 1 }
                                )
                                .frame(height: 52)
                            }
                            .padding(.horizontal, 24)
                            .padding(.bottom, 20)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("password".localized)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                ZStack(alignment: .trailing) {
                                    AppleLoginTextField(
                                        text: $password,
                                        placeholder: NSLocalizedString("enter_password", comment: ""),
                                        tag: 1,
                                        keyboardType: .default,
                                        returnKeyType: showTwoFactorField ? .next : .go,
                                        isSecure: !showPassword,
                                        contentType: .password,
                                        accent: themeManager.accentColor,
                                        focusTag: $focusTag,
                                        onCommit: {
                                            if showTwoFactorField {
                                                focusTag = 2
                                            } else {
                                                focusTag = nil
                                                Task { await authenticate() }
                                            }
                                        }
                                    )
                                    .frame(height: 52)
                                    .padding(.trailing, 44)

                                    Button(action: { showPassword.toggle() }) {
                                        Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                                            .font(.system(size: 17, weight: .medium))
                                            .foregroundColor(.secondary)
                                            .frame(width: 44, height: 52)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.trailing, 2)
                                    .accessibilityLabel(showPassword ? "hide_password".localized : "show_password".localized)
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.bottom, showTwoFactorField ? 24 : 32)

                            if showTwoFactorField {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("two_factor_code".localized)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    AppleLoginTextField(
                                        text: $code,
                                        placeholder: NSLocalizedString("enter_6digit_code", comment: ""),
                                        tag: 2,
                                        keyboardType: .numberPad,
                                        returnKeyType: .go,
                                        isSecure: false,
                                        contentType: .oneTimeCode,
                                        accent: themeManager.accentColor,
                                        focusTag: $focusTag,
                                        maxLength: 6,
                                        filterDigitsOnly: true,
                                        onCommit: {
                                            focusTag = nil
                                            Task { await authenticate() }
                                        },
                                        onTextChange: { newVal in
                                            if newVal.count == 6 {
                                                focusTag = nil
                                                Task { await authenticate() }
                                            }
                                        }
                                    )
                                    .frame(height: 52)
                                    .id(codeTag)
                                    Text("check_trusted_device".localized)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 24)
                                .padding(.bottom, 32)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            VStack(spacing: 16) {
                                Button(action: {
                                    focusTag = nil
                                    Task { await authenticate() }
                                }) {
                                    HStack(spacing: 12) {
                                        if isLoading {
                                            ProgressView()
                                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                                .scaleEffect(0.8)
                                        }
                                        Text(isLoading ? "verifying".localized : "add_account".localized)
                                            .font(.system(size: 17, weight: .semibold))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                                    .background(
                                        LinearGradient(
                                            colors: [themeManager.accentColor, themeManager.accentColor.opacity(0.8)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .foregroundColor(.white)
                                    .cornerRadius(16)
                                    .shadow(color: themeManager.accentColor.opacity(0.3), radius: 8, x: 0, y: 4)
                                }
                                .disabled(isLoading || email.isEmpty || password.isEmpty)

                                if !infoMessage.isEmpty {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: "info.circle.fill")
                                            .foregroundColor(themeManager.accentColor)
                                            .font(.system(size: 15))
                                        Text(infoMessage)
                                            .font(.subheadline)
                                            .foregroundColor(.primary)
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .background(themeManager.accentColor.opacity(0.08))
                                    .cornerRadius(10)
                                }

                                if !errorMessage.isEmpty {
                                    HStack(spacing: 8) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.red)
                                        Text(errorMessage)
                                            .font(.caption)
                                            .foregroundColor(.red)
                                            .multilineTextAlignment(.center)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .background(Color.red.opacity(0.1))
                                    .cornerRadius(8)
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("cancel".localized) {
                        focusTag = nil
                        dismiss()
                    }
                    .foregroundColor(.primary)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    focusTag = 0
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func authenticate() async {
        if email.isEmpty || password.isEmpty {
            errorMessage = "enter_full_credentials".localized
            return
        }

        if showTwoFactorField && code.count != 6 {
            errorMessage = "enter_6digit_code_verify".localized
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusTag = 2
            }
            return
        }

        isLoading = true
        errorMessage = ""
        infoMessage = ""

        do {
            try await vm.loginAccount(
                email: email,
                password: password,
                code: showTwoFactorField ? code : nil
            )
            dismiss()
        } catch {
            isLoading = false

            if let storeError = error as? StoreError {
                switch storeError {
                case .invalidCredentials:
                    errorMessage = "wrong_credentials".localized
                case .codeRequired:
                    handleTwoFactorAuthRequired()
                case .lockedAccount:
                    errorMessage = "account_locked".localized
                case .networkError:
                    errorMessage = "network_error_retry".localized
                case .authenticationFailed:
                    errorMessage = "auth_failed".localized
                case .invalidResponse:
                    errorMessage = "invalid_server_response".localized
                case .unknownError:
                    errorMessage = "unknown_error".localized
                default:
                    errorMessage = String(format: "auth_error".localized, storeError.localizedDescription)
                }
            } else {
                errorMessage = String(format: "auth_error".localized, error.localizedDescription)
            }
        }
    }

    private func handleTwoFactorAuthRequired() {
        errorMessage = ""
        if !showTwoFactorField {
            withAnimation(.easeInOut(duration: 0.3)) {
                showTwoFactorField = true
                infoMessage = "two_factor_code_intro".localized
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                focusTag = 2
            }
        } else {
            infoMessage = ""
            errorMessage = "wrong_verification_code".localized
            code = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusTag = 2
            }
        }
    }
}
private struct AppleLoginTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let tag: Int
    let keyboardType: UIKeyboardType
    let returnKeyType: UIReturnKeyType
    let isSecure: Bool
    let contentType: UITextContentType
    let accent: Color
    @Binding var focusTag: Int?
    var maxLength: Int = 0
    var filterDigitsOnly: Bool = false
    var onCommit: (() -> Void)?
    var onTextChange: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField(frame: .zero)
        tf.tag = tag
        tf.text = text
        tf.placeholder = placeholder
        tf.font = .systemFont(ofSize: 17)
        tf.textColor = .label
        tf.tintColor = UIColor(accent)
        tf.keyboardType = keyboardType
        tf.returnKeyType = returnKeyType
        tf.isSecureTextEntry = isSecure
        tf.textContentType = contentType
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
        tf.spellCheckingType = .no
        tf.smartQuotesType = .no
        tf.smartDashesType = .no
        tf.smartInsertDeleteType = .no
        tf.clearButtonMode = .whileEditing
        tf.enablesReturnKeyAutomatically = true
        if #available(iOS 17.0, *) {
            tf.inlinePredictionType = .no
        }
        if isSecure {
            if #available(iOS 12.0, *) {
                let descriptor = "required: upper; required: lower; required: digit; allowed: [-().&@?'#,/\"+!%*;<=>[\\]^_`{|}~]; minlength: 8; maxlength: 128;"
                tf.passwordRules = UITextInputPasswordRules(descriptor: descriptor)
            }
        }
        let insets = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        let wrapper = LoginTextFieldWrapper(frame: .zero, insets: insets)
        wrapper.text = text
        wrapper.placeholder = placeholder
        wrapper.font = tf.font
        wrapper.textColor = tf.textColor
        wrapper.tintColor = tf.tintColor
        wrapper.keyboardType = tf.keyboardType
        wrapper.returnKeyType = tf.returnKeyType
        wrapper.isSecureTextEntry = tf.isSecureTextEntry
        wrapper.textContentType = tf.textContentType
        wrapper.autocorrectionType = tf.autocorrectionType
        wrapper.autocapitalizationType = tf.autocapitalizationType
        wrapper.spellCheckingType = tf.spellCheckingType
        wrapper.smartQuotesType = tf.smartQuotesType
        wrapper.smartDashesType = tf.smartDashesType
        wrapper.smartInsertDeleteType = tf.smartInsertDeleteType
        wrapper.clearButtonMode = tf.clearButtonMode
        wrapper.enablesReturnKeyAutomatically = tf.enablesReturnKeyAutomatically
        if #available(iOS 17.0, *) { wrapper.inlinePredictionType = .no }
        if #available(iOS 12.0, *), isSecure {
            wrapper.passwordRules = tf.passwordRules ?? UITextInputPasswordRules(descriptor: "required: upper; required: lower; required: digit; minlength: 8; maxlength: 128;")
        }
        wrapper.tag = tag
        wrapper.delegate = context.coordinator
        wrapper.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        return wrapper
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text { uiView.text = text }
        if uiView.placeholder != placeholder { uiView.placeholder = placeholder }
        if (uiView.textColor ?? .label) != UIColor.label { uiView.textColor = .label }
        if uiView.tintColor != UIColor(accent) { uiView.tintColor = UIColor(accent) }
        if uiView.returnKeyType != returnKeyType { uiView.returnKeyType = returnKeyType }
        if uiView.isSecureTextEntry != isSecure { uiView.isSecureTextEntry = isSecure }

        DispatchQueue.main.async {
            if focusTag == tag, uiView.window != nil {
                if !uiView.isFirstResponder {
                    uiView.becomeFirstResponder()
                }
            } else if focusTag != tag && uiView.isFirstResponder {
                uiView.resignFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AppleLoginTextField
        init(_ parent: AppleLoginTextField) { self.parent = parent }

        @objc func editingChanged(_ tf: UITextField) {
            var value = tf.text ?? ""
            if parent.filterDigitsOnly {
                value = String(value.filter { $0.isNumber })
            }
            if parent.maxLength > 0 && value.count > parent.maxLength {
                value = String(value.prefix(parent.maxLength))
            }
            if value != (tf.text ?? "") {
                tf.text = value
            }
            if parent.text != value {
                parent.text = value
            }
            parent.onTextChange?(value)
        }

        func textFieldDidBeginEditing(_ tf: UITextField) {
            if parent.focusTag != tf.tag {
                DispatchQueue.main.async {
                    self.parent.focusTag = tf.tag
                }
            }
        }

        func textFieldDidEndEditing(_ tf: UITextField) {
            editingChanged(tf)
        }

        func textFieldShouldReturn(_ tf: UITextField) -> Bool {
            parent.onCommit?()
            return true
        }

        func textField(_ tf: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            let current = (tf.text ?? "") as NSString
            let next = current.replacingCharacters(in: range, with: string)
            if parent.filterDigitsOnly, !string.isEmpty {
                if !next.allSatisfy(\.isNumber) { return false }
            }
            if parent.maxLength > 0 && next.count > parent.maxLength {
                let limited = String(next.prefix(parent.maxLength))
                if tf.text != limited { tf.text = limited }
                if parent.text != limited { parent.text = limited }
                parent.onTextChange?(limited)
                return false
            }
            return true
        }
    }
}

private final class LoginTextFieldWrapper: UITextField {
    private let insets: UIEdgeInsets
    private let nominalHeight: CGFloat = 52

    init(frame: CGRect, insets: UIEdgeInsets) {
        self.insets = insets
        super.init(frame: frame)
        backgroundColor = UIColor.systemGray6.withAlphaComponent(0.55)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.systemGray4.withAlphaComponent(0.6).cgColor
        clipsToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        font = .systemFont(ofSize: 17)
        setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        let h = heightAnchor.constraint(equalToConstant: nominalHeight)
        h.priority = .required
        h.isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        var s = super.intrinsicContentSize
        s.height = max(s.height, nominalHeight)
        return s
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        var s = super.sizeThatFits(size)
        s.height = max(s.height, nominalHeight)
        return s
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        var s = super.systemLayoutSizeFitting(targetSize)
        s.height = max(s.height, nominalHeight)
        return s
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        var s = super.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority
        )
        s.height = max(s.height, nominalHeight)
        return s
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: insets) }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: insets) }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: insets) }
    override func clearButtonRect(forBounds bounds: CGRect) -> CGRect {
        let r = super.clearButtonRect(forBounds: bounds)
        return r.offsetBy(dx: -6, dy: 0)
    }
}
