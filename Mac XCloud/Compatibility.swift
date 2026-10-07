//
//  Compatibility.swift
//  Mac XCloud
//
//  Thin wrappers that adopt the macOS 14 API style while the app still runs
//  on macOS 12 and 13, where the modern replacements don't exist yet.
//

import AppKit
import SwiftUI

extension View {
    /// Runs `action` when `value` changes. Uses the non-deprecated
    /// `onChange` with a zero-parameter action closure on macOS 14+;
    /// macOS 12 and 13 fall back to the older `perform:` form.
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, perform action: @escaping () -> Void) -> some View {
        if #available(macOS 14.0, *) {
            onChange(of: value) { action() }
        } else {
            onChange(of: value) { _ in action() }
        }
    }

    /// Same as the zero-parameter version, for actions that need the new
    /// value (the two-parameter macOS 14 closure under the hood).
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, perform action: @escaping (_ newValue: V) -> Void) -> some View {
        if #available(macOS 14.0, *) {
            onChange(of: value) { _, newValue in action(newValue) }
        } else {
            onChange(of: value, perform: action)
        }
    }
}

extension NSApplication {
    /// Brings the app forward. Uses the modern `activate()` on macOS 14+
    /// (which now reliably activates even when another app is frontmost);
    /// macOS 12 and 13 keep the deprecated `activate(ignoringOtherApps:)`.
    func activateIgnoringOtherAppsCompat(_ ignoringOtherApps: Bool) {
        if #available(macOS 14.0, *) {
            activate()
        } else {
            activate(ignoringOtherApps: ignoringOtherApps)
        }
    }
}
