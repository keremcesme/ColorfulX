//
//  MetalView+UIKit.swift
//
//
//  Created by 秋星桥 on 2024/8/13.
//

#if canImport(UIKit)
    import UIKit

    open class UIMetalView: UIView {
        var metalLink: MetalLink? = try? .init()
        var qualifiedForUpdate: Bool = false

        init() {
            super.init(frame: .zero)
            backgroundColor = .clear
            layer.isOpaque = false
            layer.backgroundColor = UIColor.clear.cgColor

            guard let metalLink else { return }

            isUserInteractionEnabled = false

            layer.actions = [
                "position": NSNull(),
                "bounds": NSNull(),
                "frame": NSNull(),
                "transform": NSNull(),
                "sublayerTransform": NSNull(),
            ]
            layer.addSublayer(metalLink.metalLayer)
            metalLink.displayLink.context = .view(self)
            metalLink.onSynchronizationUpdate = { [weak self] in
                self?.vsyncCheckQualificationAndSend()
            }
        }

        @available(*, unavailable)
        public required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit { metalLink = nil }

        private func updateQualificationCheck() {
            let qualified = [
                window != nil,
                frame.width > 0,
                frame.height > 0,
                alpha > 0,
                !isHidden,
            ].allSatisfy(\.self)
            let becameQualified = qualified && !qualifiedForUpdate
            qualifiedForUpdate = qualified
            // Nothing was drawn while the view did not qualify, so draw once on return.
            if becameQualified { viewNeedsFreshFrame() }
            refreshDisplayLinkPause()
        }

        /// Whether the view still has something to draw on a coming frame.
        /// While it does not, the display link is paused.
        func hasPendingWork() -> Bool { false }

        /// Asks the view to draw its current state on the next frame.
        func viewNeedsFreshFrame() {}

        /// Runs the display link only while the view qualifies and has work,
        /// and writes `isPaused` only on a change because each write rebinds the link.
        func refreshDisplayLinkPause() {
            guard let displayLink = metalLink?.displayLink else { return }
            let shouldPause = !(qualifiedForUpdate && hasPendingWork())
            if displayLink.isPaused != shouldPause {
                displayLink.isPaused = shouldPause
            }
        }

        override open var frame: CGRect {
            get { super.frame }
            set {
                CATransaction.begin()
                CATransaction.setDisableActions(true)

                super.frame = newValue
                CATransaction.commit()
                updateQualificationCheck()
            }
        }

        override open var bounds: CGRect {
            get { super.bounds }
            set {
                CATransaction.begin()
                CATransaction.setDisableActions(true)

                super.bounds = newValue
                CATransaction.commit()
            }
        }

        override open var center: CGPoint {
            get { super.center }
            set {
                CATransaction.begin()
                CATransaction.setDisableActions(true)

                super.center = newValue
                CATransaction.commit()
            }
        }

        override open var isHidden: Bool {
            get { super.isHidden }
            set {
                super.isHidden = newValue
                updateQualificationCheck()
            }
        }

        override open var alpha: CGFloat {
            get { super.alpha }
            set {
                super.alpha = newValue
                updateQualificationCheck()
            }
        }

        override open func didMoveToWindow() {
            super.didMoveToWindow()
            updateQualificationCheck()
        }

        override open func didMoveToSuperview() {
            super.didMoveToSuperview()
            updateQualificationCheck()
        }

        private func vsyncCheckQualificationAndSend() {
            guard qualifiedForUpdate else {
                refreshDisplayLinkPause()
                return
            }
            vsync()
            refreshDisplayLinkPause()
        }

        func vsync() {}

        override open func layoutSubviews() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            super.layoutSubviews()
            updateQualificationCheck()
            if metalLink?.updateDrawableSize(withBounds: bounds) == true {
                viewNeedsFreshFrame()
            }

            CATransaction.commit()
        }
    }
#endif
