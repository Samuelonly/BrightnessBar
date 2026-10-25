import AppKit

/// The popover: centered title, slider row, status + power button.
/// Fixed 20pt side safe area, 4pt slider–label gap, 138pt slider.
/// Width is pinned by constraints: 20 + 138 + 4 + 44 + 20 = 226.
final class PanelController: NSViewController {
    private let controller: BrightnessController

    private let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let percentLabel = NSTextField(labelWithString: "50%")
    private let statusLabel = NSTextField(labelWithString: "读取中…")

    init(controller: BrightnessController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let content = NSView()

        let title = NSTextField(labelWithString: "屏幕亮度")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved)

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        percentLabel.alignment = .right

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let quitButton = NSButton()
        quitButton.isBordered = false
        quitButton.toolTip = "退出"
        if let image = NSImage(systemSymbolName: "power", accessibilityDescription: "退出")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) {
            quitButton.image = image
        } else {
            quitButton.title = "退出"
        }
        quitButton.target = self
        quitButton.action = #selector(quit)

        for sub in [title, slider, percentLabel, statusLabel, quitButton] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(sub)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            title.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            slider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            slider.widthAnchor.constraint(equalToConstant: 138),
            slider.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),

            percentLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 4),
            percentLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            percentLabel.widthAnchor.constraint(equalToConstant: 44),
            percentLabel.centerYAnchor.constraint(equalTo: slider.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusLabel.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 12),

            quitButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            quitButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: quitButton.leadingAnchor, constant: -12),

            content.bottomAnchor.constraint(greaterThanOrEqualTo: statusLabel.bottomAnchor, constant: 14),
            content.bottomAnchor.constraint(greaterThanOrEqualTo: quitButton.bottomAnchor, constant: 14),
        ])

        view = content
        controller.onUpdate = { [weak self] state in self?.apply(state) }
    }

    /// Called right before the popover shows: re-read every panel.
    func prepare() {
        slider.isEnabled = false
        statusLabel.stringValue = "读取中…"
        controller.refresh()
    }

    private func apply(_ state: BrightnessController.UIState) {
        guard view.window != nil else { return }
        slider.isEnabled = state.interactive
        statusLabel.stringValue = state.status
        percentLabel.stringValue = "\(state.percent)%"
        slider.doubleValue = Double(state.percent)
    }

    @objc private func sliderMoved() {
        let percent = Int(slider.doubleValue.rounded())
        percentLabel.stringValue = "\(percent)%"
        controller.requestSet(percent)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
