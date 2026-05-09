//
//  AppWorkerFocusRestorationTests.swift
//  HivecrewTests
//

import Foundation
import Testing
@testable import Hivecrew

@Test
func restoresWhenBackgroundTargetBecomesFrontmost() {
    #expect(AppWorkerFocusRestoration.shouldRestore(
        priorWorkspacePid: 100,
        priorVisualPid: 100,
        currentWorkspacePid: 200,
        currentVisualPid: 200,
        targetPid: 200,
        targetIsActive: true
    ))
}

@Test
func restoresWhenBackgroundTargetStealsActiveFocusWithoutBecomingFrontmost() {
    #expect(AppWorkerFocusRestoration.shouldRestore(
        priorWorkspacePid: 100,
        priorVisualPid: 100,
        currentWorkspacePid: 200,
        currentVisualPid: 100,
        targetPid: 200,
        targetIsActive: true
    ))
}

@Test
func restoresToVisualFrontmostWhenWorkspaceFrontmostWasAlreadyTarget() {
    #expect(AppWorkerFocusRestoration.shouldRestore(
        priorWorkspacePid: 200,
        priorVisualPid: 100,
        currentWorkspacePid: 200,
        currentVisualPid: 100,
        targetPid: 200,
        targetIsActive: true
    ))
}

@Test
func normalizesBeforeBackgroundActionWhenTargetIsActiveButNotVisible() {
    #expect(AppWorkerFocusRestoration.shouldNormalizeBeforeBackgroundAction(
        targetPid: 200,
        visualPid: 100,
        targetIsActive: true
    ))
}

@Test
func doesNotNormalizeBeforeBackgroundActionWhenTargetIsVisible() {
    #expect(!AppWorkerFocusRestoration.shouldNormalizeBeforeBackgroundAction(
        targetPid: 200,
        visualPid: 200,
        targetIsActive: true
    ))
}

@Test
func doesNotNormalizeBeforeBackgroundActionWhenTargetIsNotActive() {
    #expect(!AppWorkerFocusRestoration.shouldNormalizeBeforeBackgroundAction(
        targetPid: 200,
        visualPid: 100,
        targetIsActive: false
    ))
}

@Test
func doesNotRestoreWhenTargetWasAlreadyFrontmostAndVisible() {
    #expect(!AppWorkerFocusRestoration.shouldRestore(
        priorWorkspacePid: 200,
        priorVisualPid: 200,
        currentWorkspacePid: 200,
        currentVisualPid: 200,
        targetPid: 200,
        targetIsActive: true
    ))
}

@Test
func doesNotRestoreWhenAnotherAppIsVisuallyFrontmost() {
    #expect(!AppWorkerFocusRestoration.shouldRestore(
        priorWorkspacePid: 100,
        priorVisualPid: 100,
        currentWorkspacePid: 200,
        currentVisualPid: 300,
        targetPid: 200,
        targetIsActive: true
    ))
}

@Test
func doesNotRestoreWhenTargetIsNotActive() {
    #expect(!AppWorkerFocusRestoration.shouldRestore(
        priorWorkspacePid: 100,
        priorVisualPid: 100,
        currentWorkspacePid: 200,
        currentVisualPid: 100,
        targetPid: 200,
        targetIsActive: false
    ))
}

@Test
func doesNotRestoreWithoutCompleteFocusState() {
    #expect(!AppWorkerFocusRestoration.shouldRestore(
        priorWorkspacePid: nil,
        priorVisualPid: nil,
        currentWorkspacePid: 200,
        currentVisualPid: 200,
        targetPid: 200,
        targetIsActive: true
    ))
    #expect(!AppWorkerFocusRestoration.shouldRestore(
        priorWorkspacePid: 100,
        priorVisualPid: 100,
        currentWorkspacePid: nil,
        currentVisualPid: nil,
        targetPid: 200,
        targetIsActive: true
    ))
    #expect(!AppWorkerFocusRestoration.shouldRestore(
        priorWorkspacePid: 100,
        priorVisualPid: 100,
        currentWorkspacePid: 200,
        currentVisualPid: 200,
        targetPid: nil,
        targetIsActive: true
    ))
}
